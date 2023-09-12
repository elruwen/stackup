# frozen_string_literal: true

require "clamp"
require "console_logger"
require "multi_json"
require "securerandom"
require "stackup"
require "stackup/differ"
require "stackup/source"
require "stackup/version"
require "stackup/yaml"

module Stackup

  class MainCommand < Clamp::Command

    option ["-L", "--list"], :flag, "list stacks" do
      list_stacks
      exit 0
    end

    option ["-Y", "--yaml"], :flag, "output data in YAML format"

    option ["--region"], "REGION", "set region" do |arg|
      raise ArgumentError, "#{arg.inspect} doesn't look like a region" unless arg =~ /^[a-z]{2}-[a-z]+-\d$/

      arg
    end

    option ["--with-role"], "ROLE_ARN", "assume this role",
           :attribute_name => :role_arn

    option ["--retry-limit"], "N", "maximum number of retries for API calls",
           :environment_variable => "AWS_API_RETRY_LIMIT" do |arg|
      Integer(arg)
    end

    option ["--[no-]wait"], :flag, "wait for stack updates to complete",
           :default => true

    option ["--wait-poll-interval"], "N", "polling interval (in seconds) while waiting for updates",
           :default => 5, &method(:Integer)

    option "--debug", :flag, "enable debugging"

    option ["--version"], :flag, "display version" do
      puts "stackup v#{Stackup::VERSION}"
      exit 0
    end

    parameter "NAME", "Name of stack", :attribute_name => :stack_name

    def run(arguments)
      super(arguments)
    rescue Stackup::Source::ReadError => e
      signal_error e.message
    rescue Stackup::ServiceError => e
      signal_error e.message
    rescue Aws::Errors::MissingCredentialsError
      signal_error "no credentials provided"
    rescue Aws::Errors::ServiceError => e
      signal_error e.message
    end

    private

    def logger
      @logger ||= ConsoleLogger.new($stdout, debug?)
    end

    def format_data(data)
      if yaml?
        YAML.dump(data)
      else
        MultiJson.dump(data, :pretty => true)
      end
    end

    def display_data(data)
      puts format_data(data)
    end

    def role_arn=(arg)
      raise ArgumentError, "#{arg.inspect} doesn't look like a role ARN" unless arg =~ %r{^arn:aws:iam::\d+:role/}

      @role_arn = arg
    end

    def stackup
      Stackup(aws_config)
    end

    # In standard retry_mode max_attempts = 3 so the SDK will only retry twice (initial request + 2 retries)
    # Now we're setting max_attempts = 50 (initial request + 49 retries) which gives us some breathing room
    MAX_SDK_ATTEMPTS = 50

    def base_aws_config
      {
        :log_level => :debug,
        :logger => logger,
        :region => region,
        :retry_limit => retry_limit,
        :max_attempts => MAX_SDK_ATTEMPTS,
        :retry_mode => "standard"
      }.reject { |_k, v| v.nil? }
    end

    def aws_config
      return base_aws_config unless role_arn

      assumed_credentials = Aws::AssumeRoleCredentials.new(
        :client => Aws::STS::Client.new(base_aws_config),
        :role_arn => role_arn,
        :role_session_name => "stackup-#{SecureRandom.hex(8)}"
      )
      base_aws_config.merge(:credentials => assumed_credentials)
    end

    def stack
      stackup.stack(stack_name, :wait => wait?, :wait_poll_interval => wait_poll_interval)
    end

    def list_stacks
      stackup.stack_names.each do |name|
        puts name
      end
    end

    def report_change
      final_status = yield
      puts final_status unless final_status.nil?
    end

    subcommand "status", "Print stack status." do

      def execute
        puts stack.status
      end

    end

    module HasParameters

      extend Clamp::Option::Declaration

      option ["-p", "--parameters"], "FILE", "parameters file (last wins)",
             :multivalued => true,
             :attribute_name => :parameter_sources,
             &Stackup::Source.method(:new)

      option ["-o", "--override"], "PARAM=VALUE", "parameter overrides",
             :multivalued => true,
             :attribute_name => :override_list

      private

      def parameters
        parameters_from_files.merge(parameter_overrides)
      end

      def parameters_from_files
        parameter_sources.map do |src|
          Stackup::Parameters.new(src.data).to_hash
        end.inject({}, :merge)
      end

      def parameter_overrides
        {}.tap do |result|
          override_list.each do |override|
            key, value = override.split("=", 2)
            result[key] = value
          end
        end
      end

    end

    subcommand "up", "Create/update the stack." do

      option ["-t", "--template"], "FILE", "template source",
             :attribute_name => :template_source,
             &Stackup::Source.method(:new)

      option ["-T", "--use-previous-template"], :flag,
             "reuse the existing template"

      option ["-P", "--preserve-template-formatting"], :flag,
             "do not normalise the template when calling the Cloudformation APIs; useful for preserving YAML and comments"

      include HasParameters

      option "--tags", "FILE", "stack tags file",
             :attribute_name => :tag_source,
             &Stackup::Source.method(:new)

      option "--policy", "FILE", "stack policy file",
             :attribute_name => :policy_source,
             &Stackup::Source.method(:new)

      option "--service-role-arn", "SERVICE_ROLE_ARN", "cloudformation service role ARN" do |arg|
        raise ArgumentError, "#{arg.inspect} doesn't look like a role ARN" unless arg =~ %r{^arn:aws:iam::\d+:role/}

        arg
      end

      option "--on-failure", "ACTION",
             "when stack creation fails: DO_NOTHING, ROLLBACK, or DELETE",
             :default => "ROLLBACK"

      option "--capability", "CAPABILITY", "cloudformation capability",
             :multivalued => true, :default => ["CAPABILITY_NAMED_IAM"]

      def execute
        signal_usage_error "Specify either --template or --use-previous-template" unless template_source || use_previous_template?
        options = {}
        if template_source
          if template_source.s3?
            options[:template_url] = template_source.location
          else
            options[:template] = template_source.data
            options[:template_orig] = template_source.body
          end
        end
        options[:on_failure] = on_failure
        options[:parameters] = parameters
        options[:tags] = tag_source.data if tag_source
        if policy_source
          if policy_source.s3?
            options[:stack_policy_url] = policy_source.location
          else
            options[:stack_policy] = policy_source.data
          end
        end
        options[:role_arn] = service_role_arn if service_role_arn
        options[:use_previous_template] = use_previous_template?
        options[:capabilities] = capability_list
        options[:preserve] = preserve_template_formatting?
        report_change do
          stack.create_or_update(options)
        end
      end

    end

    subcommand ["change-sets"], "List change-sets." do

      def execute
        stack.change_set_summaries.each do |change_set|
          puts [
            pad(change_set.change_set_name, 36),
            pad(change_set.status, 20),
            pad(change_set.execution_status, 24)
          ].join("  ")
        end
      end

      def pad(s, width)
        (s || "").ljust(width)
      end

    end

    subcommand ["change-set"], "Change-set operations." do

      option "--name", "NAME", "Name of change-set",
             :attribute_name => :change_set_name,
             :default => "pending"

      subcommand "create", "Create a change-set." do

        option ["-d", "--description"], "DESC",
               "Change-set description"

        option ["-t", "--template"], "FILE", "template source",
               :attribute_name => :template_source,
               &Stackup::Source.method(:new)

        option ["-T", "--use-previous-template"], :flag,
               "reuse the existing template"

        option ["-P", "--preserve-template-formatting"], :flag,
               "do not normalise the template when calling the Cloudformation APIs; useful for preserving YAML and comments"

        option ["--force"], :flag,
               "replace existing change-set of the same name"

        option ["--no-fail-on-empty-change-set"], :flag, "don't fail on empty change-set",
               :attribute_name => :allow_empty_change_set

        include HasParameters

        option "--tags", "FILE", "stack tags file",
               :attribute_name => :tag_source,
               &Stackup::Source.method(:new)

        option "--service-role-arn", "SERVICE_ROLE_ARN", "cloudformation service role ARN" do |arg|
          raise ArgumentError, "#{arg.inspect} doesn't look like a role ARN" unless arg =~ %r{^arn:aws:iam::\d+:role/}

          arg
        end

        option "--capability", "CAPABILITY", "cloudformation capability",
               :multivalued => true, :default => ["CAPABILITY_NAMED_IAM"]

        def execute
          signal_usage_error "Specify either --template or --use-previous-template" unless template_source || use_previous_template?
          options = {}
          if template_source
            if template_source.s3?
              options[:template_url] = template_source.location
            else
              options[:template] = template_source.data
              options[:template_orig] = template_source.body
            end
          end
          options[:parameters] = parameters
          options[:description] = description if description
          options[:tags] = tag_source.data if tag_source
          options[:role_arn] = service_role_arn if service_role_arn
          options[:use_previous_template] = use_previous_template?
          options[:force] = force?
          options[:allow_empty_change_set] = allow_empty_change_set?
          options[:capabilities] = capability_list
          options[:preserve] = preserve_template_formatting?
          report_change do
            change_set.create(options)
          end
        end

      end

      subcommand "changes", "Describe the change-set." do

        def execute
          display_data(change_set.describe.changes.map(&:to_h))
        end

      end

      subcommand "inspect", "Show full change-set details." do

        def execute
          display_data(change_set.describe.to_h)
        end

      end

      subcommand ["apply", "execute"], "Apply the change-set." do

        def execute
          report_change do
            change_set.execute
          end
        end

      end

      subcommand "delete", "Delete the change-set." do

        def execute
          report_change do
            change_set.delete
          end
        end

      end

      def change_set
        stack.change_set(change_set_name)
      end

    end

    subcommand "diff", "Compare template/params to current stack." do

      option "--diff-format", "FORMAT", "'text', 'color', or 'html'", :default => "color"

      option ["-C", "--context-lines"], "LINES", "number of lines of context to show", :default => 10_000

      option ["-t", "--template"], "FILE", "template source",
             :attribute_name => :template_source,
             &Stackup::Source.method(:new)

      include HasParameters

      option "--tags", "FILE", "stack tags file",
             :attribute_name => :tag_source,
             &Stackup::Source.method(:new)

      def execute
        current = {}
        planned = {}
        if template_source
          current["Template"] = stack.template
          planned["Template"] = template_source.data
        end
        unless parameter_sources.empty?
          current["Parameters"] = existing_parameters.sort.to_h
          planned["Parameters"] = new_parameters.sort.to_h
        end
        if tag_source
          current["Tags"] = stack.tags.sort.to_h
          planned["Tags"] = tag_source.data.sort.to_h
        end
        signal_usage_error "specify '--template' or '--parameters'" if planned.empty?
        puts differ.diff(current, planned, context_lines)
      end

      def differ
        Stackup::Differ.new(diff_format, &method(:format_data))
      end

      def existing_parameters
        @existing_parameters ||= stack.parameters
      end

      def new_parameters
        existing_parameters.merge(parameters)
      end

    end

    subcommand ["down", "delete"], "Remove the stack." do

      def execute
        report_change do
          stack.delete
        end
      end

    end

    subcommand "cancel-update", "Cancel the update in-progress." do

      def execute
        report_change do
          stack.cancel_update
        end
      end

    end

    subcommand "wait", "Wait until stack is stable." do

      def execute
        puts stack.wait
      end

    end

    subcommand "events", "List stack events." do

      option ["-f", "--follow"], :flag, "follow new events"
      option ["--data"], :flag, "display events as data"

      def execute
        stack.watch(false) do |watcher|
          loop do
            watcher.each_new_event do |event|
              display_event(event)
            end
            break unless follow?

            sleep 5
          end
        end
      end

      def display_event(e)
        if data?
          display_data(event_data(e))
        else
          puts event_summary(e)
        end
      end

      def event_data(e)
        {
          "timestamp" => e.timestamp.localtime,
          "logical_resource_id" => e.logical_resource_id,
          "physical_resource_id" => e.physical_resource_id,
          "resource_status" => e.resource_status,
          "resource_status_reason" => e.resource_status_reason
        }.reject { |_k, v| blank?(v) }
      end

      def blank?(v)
        v.nil? || v.respond_to?(:empty?) && v.empty?
      end

      def event_summary(e)
        summary = "[#{e.timestamp.localtime.iso8601}] #{e.logical_resource_id}"
        summary += " - #{e.resource_status}"
        summary += " - #{e.resource_status_reason}" if e.resource_status_reason
        summary
      end

    end

    subcommand "template", "Display stack template." do

      def execute
        display_data(stack.template)
      end

    end

    subcommand ["parameters", "params"], "Display stack parameters." do

      def execute
        display_data(stack.parameters)
      end

    end

    subcommand "tags", "Display stack tags." do

      def execute
        display_data(stack.tags)
      end

    end

    subcommand "resources", "Display stack resources." do

      def execute
        display_data(stack.resources)
      end

    end

    subcommand "outputs", "Display stack outputs." do

      def execute
        display_data(stack.outputs)
      end

    end

    subcommand "inspect", "Display stack particulars." do

      def execute
        data = {
          "Status" => stack.status,
          "Parameters" => stack.parameters,
          "Tags" => stack.tags,
          "Resources" => stack.resources,
          "Outputs" => stack.outputs
        }
        display_data(data)
      end

    end

  end

end
