require "diaspora_federation/logging"

require "diaspora_federation/callbacks"
require "diaspora_federation/properties_dsl"
require "diaspora_federation/entity"
require "diaspora_federation/validators"

require "diaspora_federation/fetcher"

require "diaspora_federation/signing"
require "diaspora_federation/entities"

require "diaspora_federation/discovery"
require "diaspora_federation/salmon"
require "diaspora_federation/federation"

# diaspora* federation library
module DiasporaFederation
  extend Logging

  @callbacks = Callbacks.new %i(
    fetch_person_for_webfinger
    fetch_person_for_hcard
    save_person_after_webfinger
    fetch_private_key_by_diaspora_id
    fetch_author_private_key_by_entity_guid
    fetch_public_key_by_diaspora_id
    fetch_author_public_key_by_entity_guid
    entity_author_is_local?
    fetch_entity_author_id_by_guid
    queue_public_receive
    queue_private_receive
    save_entity_after_receive
  )

  # defaults
  @http_concurrency = 20
  @http_timeout = 30
  @http_verbose = false
  @http_redirect_limit = 4
  @http_user_agent = "DiasporaFederation/#{DiasporaFederation::VERSION}"

  class << self
    # {Callbacks} instance with defined callbacks
    # @see Callbacks#on
    # @see Callbacks#trigger
    attr_reader :callbacks

    # the pod url
    #
    # @example with uri
    #   config.server_uri = URI("http://localhost:3000/")
    # @example with configured pod_uri
    #   config.server_uri = AppConfig.pod_uri
    attr_accessor :server_uri

    # Set the bundle of certificate authorities (CA) certificates
    #
    # @example
    #   config.certificate_authorities = AppConfig.environment.certificate_authorities.get
    attr_accessor :certificate_authorities

    # Maximum number of parallel HTTP requests made to other pods
    #
    # @example
    #   config.http_concurrency = AppConfig.settings.typhoeus_concurrency.to_i
    attr_accessor :http_concurrency

    # timeout in seconds for http-requests
    attr_accessor :http_timeout

    # Turn on extra verbose output when sending stuff.
    #
    # @example
    #   config.http_verbose = AppConfig.settings.typhoeus_verbose?
    attr_accessor :http_verbose

    # max redirects to follow
    attr_reader :http_redirect_limit

    # user agent used for http-requests
    attr_reader :http_user_agent

    # configure the federation library
    #
    # @example
    #   DiasporaFederation.configure do |config|
    #     config.server_uri = URI("http://localhost:3000/")
    #
    #     config.define_callbacks do
    #       # callback configuration
    #     end
    #   end
    def configure
      yield self
    end

    # define the callbacks
    #
    # In order to communicate with the application which uses the diaspora_federation gem
    # callbacks are introduced. The callbacks are used for getting required data from the
    # application or posting data to the application.
    #
    # Callbacks are implemented at the application side and must follow these specifications:
    #
    # fetch_person_for_webfinger
    #   Fetches person data from the application to form a WebFinger reply
    #   @param [String] Diaspora ID of the person
    #   @return [DiasporaFederation::Discovery::WebFinger] person webfinger data
    #
    # fetch_person_for_hcard
    #   Fetches person data from the application to reply for an HCard query
    #   @param [String] guid of the person
    #   @return [DiasporaFederation::Discovery::HCard] person hcard data
    #
    # save_person_after_webfinger
    #   After the gem had made a person discovery using WebFinger it calls this callback
    #   so the application saves the person data
    #   @param [DiasporaFederation::Entities::Person] person data
    #
    # fetch_private_key_by_diaspora_id
    #   Fetches a private key of a person by her Diaspora ID from the application
    #   @param [String] Diaspora ID of the person
    #   @return [OpenSSL::PKey::RSA] key
    #
    # fetch_author_private_key_by_entity_guid
    #   Fetches a private key of the person who authored an entity identified by a given guid
    #   @param [String] entity type (Post, Comment, Like, etc)
    #   @param [String] guid of the entity
    #   @return [OpenSSL::PKey::RSA] key
    #
    # fetch_public_key_by_diaspora_id
    #   Fetches a public key of a person by her Diaspora ID from the application
    #   @param [String] Diaspora ID of the person
    #   @return [OpenSSL::PKey::RSA] key
    #
    # fetch_author_public_key_by_entity_guid
    #   Fetches a public key of the person who authored an entity identified by a given guid
    #   @param [String] entity type (Post, Comment, Like, etc)
    #   @param [String] guid of the entity
    #   @return [OpenSSL::PKey::RSA] key
    #
    # entity_author_is_local?
    #   Reports if the author of the entity identified by a given guid is local on the pod
    #   where we operate.
    #   @param [String] entity type (Post, Comment, Like, etc)
    #   @param [String] guid of the entity
    #   @return [Boolean]
    #
    # fetch_entity_author_id_by_guid
    #   Fetches Diaspora ID of the person who authored the entity identified by a given guid
    #   @param [String] entity type (Post, Comment, Like, etc)
    #   @param [String] guid of the entity
    #   @return [String] Diaspora ID of the person
    #
    # queue_public_receive
    #   Queue a public salmon xml to process in background
    #   @param [String] xml salmon xml
    #
    # queue_private_receive
    #   Queue a private salmon xml to process in background
    #   @param [String] guid guid of the receiver person
    #   @param [String] xml salmon xml
    #   @return [Boolean] true if successful, false if the user was not found
    #
    # save_entity_after_receive
    #   After the xml was parsed and processed the gem calls this callback to persist the entity
    #   @param [DiasporaFederation::Entity] entity the received entity after processing
    #
    # @see Callbacks#on
    #
    # @example
    #   config.define_callbacks do
    #     on :some_event do |arg1|
    #       # do something
    #     end
    #   end
    #
    # @param [Proc] block the callbacks to define
    def define_callbacks(&block)
      @callbacks.instance_eval(&block)
    end

    # validates if the engine is configured correctly
    #
    # called from after_initialize
    # @raise [ConfigurationError] if the configuration is incomplete or invalid
    def validate_config
      configuration_error "server_uri: Missing or invalid" unless @server_uri.respond_to? :host

      unless defined?(::Rails) && !::Rails.env.production?
        configuration_error "certificate_authorities: Not configured" if @certificate_authorities.nil?
        unless File.file? @certificate_authorities
          configuration_error "certificate_authorities: File not found: #{@certificate_authorities}"
        end
      end

      validate_http_config

      unless @callbacks.definition_complete?
        configuration_error "Missing handlers for #{@callbacks.missing_handlers.join(', ')}"
      end

      logger.info "successfully configured the federation library"
    end

    private

    def validate_http_config
      configuration_error "http_concurrency: please configure a number" unless @http_concurrency.is_a?(Fixnum)
      configuration_error "http_timeout: please configure a number" unless @http_timeout.is_a?(Fixnum)

      return unless !@http_verbose.is_a?(TrueClass) && !@http_verbose.is_a?(FalseClass)
      configuration_error "http_verbose: please configure a boolean"
    end

    def configuration_error(message)
      logger.fatal("diaspora federation configuration error: #{message}")
      raise ConfigurationError, message
    end
  end

  # raised, if the engine is not configured correctly
  class ConfigurationError < RuntimeError
  end
end
