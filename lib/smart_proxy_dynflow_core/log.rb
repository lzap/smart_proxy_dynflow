require 'logging'

module SmartProxyDynflowCore
  class Log
    BASE_LOG_SIZE = 1024 * 1024 # 1 MiB
    begin
      require 'syslog/logger'
      @syslog_available = true
    rescue LoadError
      @syslog_available = false
    end

    class << self
      def reload!
        Logging.reset
        @logger = nil
        instance
      end

      def reopen
        return if @logger.nil?
        @logger.appenders.each{|a| a.reopen}
      end

      def instance
        return @logger if @logger
        logger_name = 'dynflow-core'
        layout = Logging::Layouts.pattern(pattern: setting(:file_logging_pattern, '%d %.8X{request} [%.1l] %m') + "\n")
        notime_layout = Logging::Layouts.pattern(pattern: setting(:system_logging_pattern, '%.8X{request} [%.1l] %m') + "\n")
        log_file = setting(:log_file, 'STDOUT')
        @logger = Logging.logger.root
        if log_file.casecmp('STDOUT').zero?
          @logger.add_appenders(Logging.appenders.stdout(logger_name, layout: layout))
        elsif log_file.casecmp('SYSLOG').zero?
          unless syslog_available?
            puts "Syslog is not supported on this platform, use STDOUT or a file"
            exit(1)
          end
          @logger.add_appenders(Logging.appenders.syslog(logger_name, layout: notime_layout, facility: ::Syslog::Constants::LOG_LOCAL5))
        elsif log_file.casecmp('JOURNAL').zero? || log_file.casecmp('JOURNALD').zero?
          begin
            @logger.add_appenders(Logging.appenders.journald(logger_name, logger_name: :proxy_logger, layout: notime_layout, facility: ::Syslog::Constants::LOG_LOCAL5))
          rescue NoMethodError
            @logger.add_appenders(Logging.appenders.stdout(logger_name, layout: layout))
            @logger.warn "Journald is not available on this platform. Falling back to STDOUT."
          end
        else
          begin
            keep = setting(:file_rolling_keep, 6)
            size = BASE_LOG_SIZE * setting(:file_rolling_size, 100)
            age = setting(:file_rolling_age, 'weekly')
            @logger.add_appenders(Logging.appenders.rolling_file(logger_name, layout: layout, filename: log_file, keep: keep, size: size, age: age, roll_by: 'date'))
          rescue ArgumentError => ae
            @logger.add_appenders(Logging.appenders.stdout(logger_name, layout: layout))
            @logger.warn "Log file #{log_file} cannot be opened. Falling back to STDOUT: #{ae}"
          end
        end
        @logger.level = ::Logging.level_num(setting(:log_level, 'ERROR'))
        @logger
      end

      def setting(name, default)
        if Settings.instance.loaded && Settings.instance.send(name)
          Settings.instance.send(name)
        else
          default
        end
      end

      def with_fields(fields = {})
        ::Logging.ndc.push(fields) do
          yield
        end
      end

      # Standard way for logging exceptions to get the most data in the log. By default
      # it logs via warn level, this can be changed via options[:level]
      def exception(context_message, exception, options = {})
        level = options[:level] || :warn
        unless ::Logging::LEVELS.keys.include?(level.to_s)
          raise "Unexpected log level #{level}, expected one of #{::Logging::LEVELS.keys}"
        end
        # send class, message and stack as structured fields in addition to message string
        backtrace = exception.backtrace ? exception.backtrace : []
        extra_fields = {
          exception_class: exception.class.name,
          exception_message: exception.message,
          exception_backtrace: backtrace
        }
        extra_fields[:foreman_code] = exception.code if exception.respond_to?(:code)
        with_fields(extra_fields) do
          public_send(level) do
            ([context_message, "#{exception.class}: #{exception.message}"] + backtrace).join("\n")
          end
        end
      end
    end

    class ProxyStructuredFormater < ::Dynflow::LoggerAdapters::Formatters::Abstract
      def format(message)
        if ::Exception === message
          subject = "#{message.message} (#{message.class})"
          if @base.respond_to?(:exception)
            @base.exception("Error details", message)
            subject
          else
            "#{subject}\n#{message.backtrace.join("\n")}"
          end
        else
          message
        end
      end
    end

    class ProxyAdapter < ::Dynflow::LoggerAdapters::Simple
      def initialize(logger, level = Logger::DEBUG, _formatters = [])
        @logger           = logger
        @logger.level     = level
        @action_logger    = apply_formatters(ProgNameWrapper.new(@logger, ' action'), [ProxyStructuredFormater])
        @dynflow_logger   = apply_formatters(ProgNameWrapper.new(@logger, 'dynflow'), [ProxyStructuredFormater])
      end
    end
  end
end
