module Grape
  # The API class is the primary entry point for
  # creating Grape APIs.Users should subclass this
  # class in order to build an API.
  class API
    include Grape::DSL::API

    class << self
      attr_reader :instance
      LOCK = Mutex.new

      def reset!
        @route_set = Rack::Mount::RouteSet.new
        @endpoints = []
        @routes = nil
        reset_validations!
      end

      def compile
        @instance ||= new
      end

      def change!
        @instance = nil
      end

      def call(env)
        LOCK.synchronize { compile } unless instance
        call!(env)
      end

      def call!(env)
        instance.call(env)
      end

      # Create a scope without affecting the URL.
      #
      # @param name [Symbol] Purely placebo, just allows to name the scope to make the code more readable.
      def scope(name = nil, &block)
        within_namespace do
          nest(block)
        end
      end

      def cascade(value = nil)
        if value.nil?
          inheritable_setting.namespace_inheritable.keys.include?(:cascade) ? !!namespace_inheritable(:cascade) : true
        else
          namespace_inheritable(:cascade, value)
        end
      end

      protected

      def prepare_routes
        endpoints.map(&:routes).flatten
      end

      # Execute first the provided block, then each of the
      # block passed in. Allows for simple 'before' setups
      # of settings stack pushes.
      def nest(*blocks, &block)
        blocks.reject!(&:nil?)
        if blocks.any?
          instance_eval(&block) if block_given?
          blocks.each { |b| instance_eval(&b) }
          reset_validations!
        else
          instance_eval(&block)
        end
      end

      def inherited(subclass)
        subclass.reset!
        subclass.logger = logger.clone
      end

      def inherit_settings(other_settings)
        top_level_setting.inherit_from other_settings.point_in_time_copy

        endpoints.each(&:reset_routes!)

        @routes = nil
      end
    end

    def initialize
      @route_set = Rack::Mount::RouteSet.new
      add_head_not_allowed_methods_and_options_methods
      self.class.endpoints.each do |endpoint|
        endpoint.mount_in(@route_set)
      end

      @route_set.freeze
    end

    def call(env)
      status, headers, body = @route_set.call(env)
      headers.delete('X-Cascade') unless cascade?
      [status, headers, body]
    end

    # Some requests may return a HTTP 404 error if grape cannot find a matching
    # route. In this case, Rack::Mount adds a X-Cascade header to the response
    # and sets it to 'pass', indicating to grape's parents they should keep
    # looking for a matching route on other resources.
    #
    # In some applications (e.g. mounting grape on rails), one might need to trap
    # errors from reaching upstream. This is effectivelly done by unsetting
    # X-Cascade. Default :cascade is true.
    def cascade?
      return !!self.class.namespace_inheritable(:cascade) if self.class.inheritable_setting.namespace_inheritable.keys.include?(:cascade)
      return !!self.class.namespace_inheritable(:version_options)[:cascade] if self.class.namespace_inheritable(:version_options) && self.class.namespace_inheritable(:version_options).key?(:cascade)
      true
    end

    reset!

    private

    # For every resource add a 'OPTIONS' route that returns an HTTP 204 response
    # with a list of HTTP methods that can be called. Also add a route that
    # will return an HTTP 405 response for any HTTP method that the resource
    # cannot handle.
    def add_head_not_allowed_methods_and_options_methods
      methods_per_path = {}

      self.class.endpoints.each do |endpoint|
        routes = endpoint.routes
        routes.each do |route|
          methods_per_path[route.route_path] ||= []
          methods_per_path[route.route_path] << route.route_method
        end
      end

      # The paths we collected are prepared (cf. Path#prepare), so they
      # contain already versioning information when using path versioning.
      # Disable versioning so adding a route won't prepend versioning
      # informations again.
      without_root_prefix do
        without_versioning do
          methods_per_path.each do |path, methods|
            allowed_methods = methods.dup
            unless self.class.namespace_inheritable(:do_not_route_head)
              allowed_methods |= ['HEAD'] if allowed_methods.include?('GET')
            end

            allow_header = (['OPTIONS'] | allowed_methods).join(', ')
            unless self.class.namespace_inheritable(:do_not_route_options)
              unless allowed_methods.include?('OPTIONS')
                self.class.options(path, {}) do
                  header 'Allow', allow_header
                  status 204
                  ''
                end
              end
            end

            not_allowed_methods = %w(GET PUT POST DELETE PATCH HEAD) - allowed_methods
            not_allowed_methods << 'OPTIONS' if self.class.namespace_inheritable(:do_not_route_options)
            self.class.route(not_allowed_methods, path) do
              header 'Allow', allow_header
              status 405
              ''
            end
          end
        end
      end
    end

    def without_versioning(&block)
      old_version = self.class.namespace_inheritable(:version)
      old_version_options = self.class.namespace_inheritable(:version_options)

      self.class.namespace_inheritable_to_nil(:version)
      self.class.namespace_inheritable_to_nil(:version_options)

      yield

      self.class.namespace_inheritable(:version, old_version)
      self.class.namespace_inheritable(:version_options, old_version_options)
    end

    def without_root_prefix(&block)
      old_prefix = self.class.namespace_inheritable(:root_prefix)

      self.class.namespace_inheritable_to_nil(:root_prefix)

      yield

      self.class.namespace_inheritable(:root_prefix, old_prefix)
    end
  end
end
