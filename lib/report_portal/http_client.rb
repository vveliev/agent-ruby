require 'http'

module ReportPortal
  # @api private
  class HttpClient
    attr_accessor :logger

    def initialize(logger)
      @logger = logger
      create_client
    end

    def send_request(method, path, options = {})
      path.prepend("/api/v1/#{Settings.instance.project}/")
      path.prepend(origin) unless use_persistent?

      tries = 3

      begin
        response = @http.request(method, path, options)
      rescue StandardError => e
        logger.error("Request #{request_info(method, path)} produced an exception:")
        logger.error("TRACE[#{e.backtrace}]")
        logger.error(e)
        recreate_client
      else
        return response.parse(:json) if response.status.success?

        message = "Request #{request_info(method, path)} returned code #{response.code}."
        message << " Response:\n#{response}" unless response.to_s.empty?
        logger.error( message )
      end
    end

    private

    def create_client
      @http = HTTP.auth("Bearer #{Settings.instance.uuid}")
      @http = @http.persistent(origin) if use_persistent?
      add_insecure_ssl_options if Settings.instance.disable_ssl_verification
    end

    def add_insecure_ssl_options
      ssl_context = OpenSSL::SSL::SSLContext.new
      ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
      @http.default_options = { ssl_context: ssl_context }
    end

    # Response should be consumed before sending next request via the same persistent connection.
    # If an exception occurred, there may be no response so a connection has to be recreated.
    def recreate_client
      @http.close
      create_client
    end

    def request_info(verb, path)
      uri = URI.join(origin, path)
      "#{verb.upcase} `#{uri}`"
    end

    def origin
      Addressable::URI.parse(Settings.instance.endpoint).origin
    end

    def use_persistent?
      ReportPortal::Settings.instance.formatter_modes.include?('use_persistent_connection')
    end
  end
end
