require 'http'

module ReportPortal
  # @api private
  class HttpClient
    attr_accessor :logger

    def initialize(logger)
      @logger = logger
      create_client
    end


    def send_request(verb, path, options = {})
      path.prepend("/api/v1/#{Settings.instance.project}/")
      path.prepend(origin) unless use_persistent?

      tries = 3

      begin
        response = @http.request(verb, path, options)
      rescue StandardError => e
        puts "Request #{request_info(verb, path)} produced an exception:"
        puts e
        recreate_client
      else
        return response.parse(:json) if response.status.success?

        message = "Request #{request_info(verb, path)} returned code #{response.code}."
        message << " Response:\n#{response}" unless response.to_s.empty?
        puts message
      end
    end

    def process_request(path, method, *options)
      tries = 5
      begin
        response = rp_client.send(method, path, *options)
      rescue Faraday::ClientError => e
        logger.error("TRACE[#{e.backtrace}]")
        response = JSON.parse(e.response[:body])
        logger.warn("Exception[#{e}], response:[#{response}]], retry_count: [#{tries}]")
        m = response['message'].match(%r{Start time of child \['(.+)'\] item should be same or later than start time \['(.+)'\] of the parent item\/launch '.+'})
        case response['error_code']
        when 4001
          return
        end

        if m
          parent_time = Time.strptime(m[2], '%a %b %d %H:%M:%S %z %Y')
          data = JSON.parse(options[0])
          logger.warn("RP error : 40025, time of a child: [#{data['start_time']}], paren time: [#{(parent_time.to_f * 1000).to_i}]")
          data['start_time'] = (parent_time.to_f * 1000).to_i + 1000
          options[0] = data.to_json
          ReportPortal.last_used_time = data['start_time']
        end

        retry unless (tries -= 1).zero?
        raise e
      rescue => error
        logger.error("Processing error retryies left: #{tries}, error: #{error.message}")
        sleep 2
        retry unless (tries -= 1).zero?
        raise error
      end
      JSON.parse(response.body)
    end


    @http_client ||= HttpClient.new
    def rp_client
      @connection ||= Faraday.new(url: Settings.instance.project_url, request: { timeout: 300 }) do |f|
        f.headers = { Authorization: "Bearer #{Settings.instance.uuid}", Accept: 'application/json', 'Content-type': 'application/json' }
        verify_ssl = Settings.instance.disable_ssl_verification
        f.ssl.verify = !verify_ssl unless verify_ssl.nil?
        f.request :multipart
        f.request :url_encoded
        f.response :raise_error
        f.adapter :net_http_persistent
      end

      @connection
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
