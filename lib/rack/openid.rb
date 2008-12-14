require 'rubygems'
require 'rack'

gem 'ruby-openid', '>=2.1.2'
require 'openid'
require 'openid/consumer'
require 'openid/extensions/sreg'
require 'openid/store/memory'

module Rack
  class OpenID
    class TimeoutResponse
      include ::OpenID::Consumer::Response
      STATUS = :failure
    end

    class MissingResponse
      include ::OpenID::Consumer::Response
      STATUS = :missing
    end

    HTTP_METHODS = %w(GET HEAD PUT POST DELETE OPTIONS)

    RESPONSE = "rack.auth.openid.response".freeze
    IDENTITY = "rack.auth.openid.identity".freeze
    IDENTIFIER = "rack.auth.openid.identifier".freeze

    def initialize(app, store = nil)
      @app = app
      @store = store || ::OpenID::Store::Memory.new
      freeze
    end

    def call(env)
      req = Rack::Request.new(env)
      if env["REQUEST_METHOD"] == "GET" && req.GET["openid.mode"]
        complete_authentication(env)
      end

      status, headers, body = @app.call(env)

      if status.to_i == 401 && (qs = headers["X-OpenID-Authenticate"])
        begin_authentication(env, qs)
      else
        [status, headers, body]
      end
    end

    private
      def begin_authentication(env, qs)
        req = Rack::Request.new(env)
        params = Rack::Utils.parse_query(qs)

        session = env["rack.session"]
        consumer = ::OpenID::Consumer.new(session, @store)
        identifier = params["identifier"]

        begin
          oidreq = consumer.begin(identifier)
          add_simple_registration_fields(oidreq, params)
          url = open_id_redirect_url(req, oidreq, params["return_to"], params["method"])
          return redirect_to(url)
        rescue ::OpenID::OpenIDError, Timeout::Error => e
          env[IDENTITY]   = identifier
          env[IDENTIFIER] = identifier
          env[RESPONSE]   = MissingResponse.new
          return self.call(env)
        end
      end

      def complete_authentication(env)
        req = Rack::Request.new(env)
        session = env["rack.session"]

        oidresp = timeout_protection_from_identity_server {
          consumer = ::OpenID::Consumer.new(session, @store)
          consumer.complete(req.params, req.url)
        }

        env[RESPONSE] = oidresp
        env[IDENTITY] = oidresp.identity_url
        env[IDENTIFIER] = oidresp.display_identifier

        if method = req.GET["_method"]
          method = method.upcase
          if HTTP_METHODS.include?(method)
            env["REQUEST_METHOD"] = method
          end
        end

        query_hash = env["rack.request.query_hash"]
        query_hash.delete("_method")
        query_hash.delete_if do |key, value|
          key =~ /^openid\./
        end

        env["QUERY_STRING"] = env["rack.request.query_string"] =
          Rack::Utils.build_query(env["rack.request.query_hash"])

        request_uri = env["PATH_INFO"]
        if env["QUERY_STRING"].any?
          request_uri << "?" + env["QUERY_STRING"]
        end
        env["REQUEST_URI"] = request_uri
      end

      def realm_url(req)
        url = req.scheme + "://"
        url << req.host

        if req.scheme == "https" && req.port != 443 ||
            req.scheme == "http" && req.port != 80
          url << ":#{req.port}"
        end

        url
      end

      def request_url(req)
        url = realm_url(req)
        url << req.script_name
        url << req.path_info
        url
      end

      def redirect_to(url)
        [303, {"Content-Type" => "text/html", "Location" => url}, []]
      end

      def open_id_redirect_url(req, oidreq, return_to = nil, method = nil)
        method ||= req.request_method
        method = method.to_s.downcase
        oidreq.return_to_args['_method'] = method unless method == "get"
        oidreq.redirect_url(realm_url(req), return_to || request_url(req))
      end

      def add_simple_registration_fields(oidreq, fields)
        sregreq = ::OpenID::SReg::Request.new

        if required = fields["required"]
          sregreq.request_fields(Array(required), true)
        end

        if optional = fields["optional"]
          sregreq.request_fields(Array(optional), false)
        end

        if policy_url = fields["policy_url"]
          sregreq.policy_url = policy_url
        end

        oidreq.add_extension(sregreq)
      end

      def timeout_protection_from_identity_server
        yield
      rescue Timeout::Error
        TimeoutResponse.new
      end
  end
end
