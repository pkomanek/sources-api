module Sources
  class BulkAssembly
    attr_reader :output

    def initialize(params)
      @sources = params[:sources]
      @endpoints = params[:endpoints]
      @applications = params[:applications]

      # separate out the superkey authentications.
      @superkeys, @authentications = params[:authentications]&.partition { |auth| auth[:authtype] == "superkey" }
    end

    def process
      Source.transaction do
        @output = {}.tap do |output|
          # Create the base source(s)
          output[:sources] = create_sources(@sources)

          # Create the superkey authentications (if there are any)
          output[:authentications] = create_authentications(@superkeys, output)

          # Create the endpoints
          output[:endpoints] = create_endpoints(@endpoints, output)

          # Create the applications (sends superkey requests via callback)
          output[:applications] = create_applications(@applications, output)

          # Create the remaining authentications that aren't superkeys.
          if output[:authentications]
            output[:authentications].concat(create_authentications(@authentications, output))
          else
            output[:authentications] = create_authentications(@authentications, output)
          end
        end

        self
      rescue => e
        Rails.logger.error("Error bulk processing from payload: Sources: #{@sources}, Endpoints: #{@endpoints}, Applications: #{@applications}, Authentications: #{@authentications}. Error: #{e}")

        raise
      end
    end

    def create_sources(sources)
      sources&.map do |source|
        # get the source type by ID or by type string
        srct = SourceType.find_by(:id => source.delete(:source_type_id)) || SourceType.find_by(:name => source.delete(:type))

        raise ActiveRecord::ActiveRecordError, "Source Type not found" if srct.nil?

        Source.create!(source.merge!(:source_type => srct))
      end
    end

    def create_endpoints(endpoints, resources)
      endpoints&.map do |endpoint|
        src = find_resource(resources, :sources, endpoint.delete(:source_name))

        Endpoint.create!(endpoint.merge!(:source_id => src.id))
      end
    end

    def create_applications(applications, resources)
      applications&.map do |app|
        src = find_resource(resources, :sources, app.delete(:source_name))
        # Get the application by id or lookup by type string
        appt = ApplicationType.find_by(:id => app.delete(:application_type_id)) || get_application_type(app.delete(:type))

        ::Application.create!(app.merge!(:source_id => src.id, :application_type_id => appt.id))
      end
    end

    def create_authentications(authentications, resources)
      authentications&.map do |auth|
        ptype = auth.delete(:resource_type)
        pname = auth.delete(:resource_name)

        # complicated logic here - since the source/endpoint/application can all
        # be looked up differently
        parent = case ptype
                 when "source"
                   find_resource(resources, :sources, pname)
                 when "endpoint"
                   find_resource(resources, :endpoints, pname, :host)
                 when "application"
                   # we have to look up the application by id before jumping
                   # into looking for the current resources since it matches by
                   # type
                   ::Application.find_by(:id => pname) || find_resource(resources, :applications, get_application_type(pname), :application_type)
                 end

        Authentication.create!(auth.merge!(:resource => parent)).tap do |newauth|
          # create the application_authentication relation if the parent was an
          # application.
          ApplicationAuthentication.create!(:authentication => newauth, :application => parent) if ptype == "application"
        end
      end
    end

    private

    def find_resource(resources, rtype, rname, field = :name)
      # use the safe operator in the case of creating a subresource on an
      # existing source
      parent = resources[rtype]&.detect { |resource| resource.send(field) == rname }

      # if the parent is a source, it's possible that it was already created in
      # the db so we need to try and look it up
      if parent.nil?
        case rtype
        when :sources
          parent = Source.find_by(:name => rname) || Source.find_by(:id => rname)
        when :endpoints
          parent = Endpoint.find_by(:host => rname) || Endpoint.find_by(:id => rname)
        end
      end

      raise ActiveRecord::ActiveRecordError, "no applicable #{rtype} for #{rname}" if parent.nil?

      parent
    end

    def get_application_type(type)
      ApplicationType.all.detect { |apptype| apptype.name.match?(type) }.tap do |found|
        raise ActiveRecord::ActiveRecordError, "no applicable application type found for #{type}" if found.nil?
      end
    end
  end
end
