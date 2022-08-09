require "oauth2"
require "omniauth"
require "securerandom"
require "socket"       # for SocketError
require "timeout"      # for Timeout::Error

module OmniAuth
  module Strategies
    # Authentication strategy for connecting with APIs constructed using
    # the [OAuth 2.0 Specification](http://tools.ietf.org/html/draft-ietf-oauth-v2-10).
    # You must generally register your application with the provider and
    # utilize an application id and secret in order to authenticate using
    # OAuth 2.0.
    class OAuth2
      include OmniAuth::Strategy

      def self.inherited(subclass)
        OmniAuth::Strategy.included(subclass)
      end

      args %i[client_id client_secret]

      option :client_id, nil
      option :client_secret, nil
      option :client_options, {}
      option :authorize_params, {}
      option :authorize_options, %i[scope state]
      option :token_params, {}
      option :token_options, []
      option :auth_token_params, {}
      option :provider_ignores_state, false
      option :pkce, false
      option :pkce_verifier, nil
      option :pkce_options, {
        :code_challenge => proc { |verifier|
          Base64.urlsafe_encode64(
            Digest::SHA2.digest(verifier),
            :padding => false,
          )
        },
        :code_challenge_method => "S256",
      }

      attr_accessor :access_token

      def client
        ::OAuth2::Client.new(options.client_id, options.client_secret, deep_symbolize(options.client_options))
      end

      credentials do
        hash = {"token" => access_token.token}
        hash["refresh_token"] = access_token.refresh_token if access_token.expires? && access_token.refresh_token
        hash["expires_at"] = access_token.expires_at if access_token.expires?
        hash["expires"] = access_token.expires?
        hash
      end

      def request_phase
        redirect client.auth_code.authorize_url({:redirect_uri => callback_url}.merge(authorize_params))
      end

      def authorize_params # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        Rails.logger.info('___authorize_params____')
        options.authorize_params[:state] = SecureRandom.hex(24)

        Rails.logger.info('options.authorize_params[:state]: ' + options.authorize_params[:state].inspect )

        if OmniAuth.config.test_mode
          @env ||= {}
          @env["rack.session"] ||= {}
        end

        params = options.authorize_params
                        .merge(options_for("authorize"))
                        .merge(pkce_authorize_params)

        session["omniauth.pkce.verifier"] = options.pkce_verifier if options.pkce
        session["omniauth.state"] = params[:state]
        session["state"] = params[:state]
        session["aaa"] = 'aaa'

        Rails.logger.info('session["omniauth.state"]: ' + session["omniauth.state"].inspect )

        params
      end

      def token_params
        options.token_params.merge(options_for("token")).merge(pkce_token_params)
      end

      def callback_phase # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        Rails.logger.info('___callback_phase____')
        Rails.logger.info('error_reason: ' + request.params["error_reason"].inspect )
        Rails.logger.info('error: ' + request.params["error"].inspect )
        Rails.logger.info('state: ' + request.params["state"].inspect )
        Rails.logger.info('session.state: ' + session["state"].inspect )
        Rails.logger.info('omniauth.state: ' + session["omniauth.state"].inspect )
        Rails.logger.info('error_description: ' + request.params["error_description"].inspect )
        Rails.logger.info('provider_ignores_state: ' + options.provider_ignores_state.inspect )
        Rails.logger.info('aaa: ' + session['aaa'].inspect )

        error = request.params["error_reason"] || request.params["error"]
        if !options.provider_ignores_state && (request.params["state"].to_s.empty? || request.params["state"] != session.delete("omniauth.state"))
          Rails.logger.error('state not valid')
          fail!(:csrf_detected, CallbackError.new(:csrf_detected, "CSRF detected"))
        elsif error
          Rails.logger.error('error')
          fail!(error, CallbackError.new(request.params["error"], request.params["error_description"] || request.params["error_reason"], request.params["error_uri"]))
        else
          Rails.logger.info('start build access token')
          self.access_token = build_access_token
          self.access_token = access_token.refresh! if access_token.expired?
          Rails.logger.info('access_token: ' + self.access_token.inspect )
          super
        end
      rescue ::OAuth2::Error, CallbackError => e
        Rails.logger.error(e.message)
        Rails.logger.error(e.backtrace.join("\n"))
        fail!(:invalid_credentials, e)
      rescue ::Timeout::Error, ::Errno::ETIMEDOUT => e
        Rails.logger.error(e.message)
        Rails.logger.error(e.backtrace.join("\n"))
        fail!(:timeout, e)
      rescue ::SocketError => e
        Rails.logger.error(e.message)
        Rails.logger.error(e.backtrace.join("\n"))
        fail!(:failed_to_connect, e)
      end

    protected

      def pkce_authorize_params
        return {} unless options.pkce

        options.pkce_verifier = SecureRandom.hex(64)

        # NOTE: see https://tools.ietf.org/html/rfc7636#appendix-A
        {
          :code_challenge => options.pkce_options[:code_challenge]
                                    .call(options.pkce_verifier),
          :code_challenge_method => options.pkce_options[:code_challenge_method],
        }
      end

      def pkce_token_params
        return {} unless options.pkce

        {:code_verifier => session.delete("omniauth.pkce.verifier")}
      end

      def build_access_token
        verifier = request.params["code"]
        client.auth_code.get_token(verifier, {:redirect_uri => callback_url}.merge(token_params.to_hash(:symbolize_keys => true)), deep_symbolize(options.auth_token_params))
      end

      def deep_symbolize(options)
        options.each_with_object({}) do |(key, value), hash|
          hash[key.to_sym] = value.is_a?(Hash) ? deep_symbolize(value) : value
        end
      end

      def options_for(option)
        hash = {}
        options.send(:"#{option}_options").select { |key| options[key] }.each do |key|
          hash[key.to_sym] = if options[key].respond_to?(:call)
                               options[key].call(env)
                             else
                               options[key]
                             end
        end
        hash
      end

      # An error that is indicated in the OAuth 2.0 callback.
      # This could be a `redirect_uri_mismatch` or other
      class CallbackError < StandardError
        attr_accessor :error, :error_reason, :error_uri

        def initialize(error, error_reason = nil, error_uri = nil)
          self.error = error
          self.error_reason = error_reason
          self.error_uri = error_uri
        end

        def message
          [error, error_reason, error_uri].compact.join(" | ")
        end
      end
    end
  end
end

OmniAuth.config.add_camelization "oauth2", "OAuth2"
