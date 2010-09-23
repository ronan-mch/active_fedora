require 'util/class_level_inheritable_attributes'
require 'active_fedora/model'
require 'active_fedora/semantic_node'
require 'solrizer/field_name_mapper'
require 'nokogiri'

SOLR_DOCUMENT_ID = "id" unless defined?(SOLR_DOCUMENT_ID)
ENABLE_SOLR_UPDATES = true unless defined?(ENABLE_SOLR_UPDATES)

module ActiveFedora
  
  # This class ties together many of the lower-level modules, and
  # implements something akin to an ActiveRecord-alike interface to
  # fedora. If you want to represent a fedora object in the ruby
  # space, this is the class you want to extend.
  #
  # =The Basics
  #   class Oralhistory < ActiveFedora::Base
  #     has_metadata :name => "properties", :type => ActiveFedora::MetadataDatastream do |m|
  #       m.field "narrator",  :string
  #       m.field "narrator",  :text
  #     end
  #   end
  #
  # The above example creates a FedoraObject with a metadata datastream named "properties", which is composed of a 
  # narrator and bio field.
  #
  # Datastreams defined with +has_metadata+ are accessed via the +datastreams+ member hash.
  #
  # =Implementation
  # This class is really a facade for a basic Fedora::FedoraObject, which is stored internally.
  class Base
    include MediaShelfClassLevelInheritableAttributes
    ms_inheritable_attributes  :ds_specs, :class_named_datastreams_desc
    include Model
    include SemanticNode
    include Solrizer::FieldNameMapper
     
    attr_accessor :named_datastreams_desc
    

    has_relationship "collection_members", :has_collection_member
    has_relationship "part_of", :is_part_of
    has_relationship "parts_inbound", :is_part_of, :inbound=>true
    has_relationship "parts_outbound", :has_part
    

    # Has this object been saved?
    def new_object?
      @new_object
    end
    
    def new_object=(bool)
      @new_object = bool
      inner_object.new_object = bool
    end
    
    # Constructor. If +attrs+  does  not comtain +:pid+, we assume we're making a new one,
    # and call off to the Fedora Rest API for the next available Fedora pid, and mark as new object.
    # 
    # If there is a pid, we're re-hydrating an existing object, and new object is false. Once the @inner_object is stored,
    # we configure any defined datastreams.
    def initialize(attrs = {})
      unless attrs[:pid]
        attrs = attrs.merge!({:pid=>Fedora::Repository.instance.nextid})  
        @new_object=true
      else
        @new_object = attrs[:new_object] == false ? false : true
      end
      @inner_object = Fedora::FedoraObject.new(attrs)
      @datastreams = {}
      configure_defined_datastreams
    end

    #This method is used to specify the details of a datastream. 
    #args must include :name. Note that this method doesn't actually
    #execute the block, but stores it at the class level, to be executed
    #by any future instantiations.
    def self.has_metadata(args, &block)
      @ds_specs ||= Hash.new
      @ds_specs[args[:name]]= [args[:type], block]
    end

    #Saves a Base object, and any dirty datastreams, then updates 
    #the Solr index for this object.
    def save
      #@metadata_is_dirty = false
      # If it's a new object, set the conformsTo relationship for Fedora CMA
      if new_object? 
        result = create
      else
        result = update
      end
      @new_object = false
      self.update_index if @metadata_is_dirty == true && ENABLE_SOLR_UPDATES
      @metadata_is_dirty == false
      return result
    end
    
    # Refreshes the object's info from Fedora
    # Note: Currently just registers any new datastreams that have appeared in fedora
    def refresh
      inner_object.load_attributes_from_fedora
      @datastreams = datastreams_in_fedora.merge(datastreams_in_memory)
    end

    #Deletes a Base object, also deletes the info indexed in Solr, and 
    #the underlying inner_object.  If this object is held in any relationships (ie inbound relationships
    #outside of this object it will remove it from those items rels-ext as well
    def delete
      inbound_relationships(:objects).each_pair do |predicate, objects|
        objects.each do |obj|
          if obj.respond_to?(:remove_relationship)
            obj.remove_relationship(predicate,self)
            obj.save
          end 
        end
      end

      Fedora::Repository.instance.delete(@inner_object)
      if ENABLE_SOLR_UPDATES
        ActiveFedora::SolrService.instance.conn.delete(pid) 
        # if defined?( Solrizer::Solrizer ) 
        #   solrizer = Solrizer::Solrizer.new
        #   solrizer.solrize_delete(pid)
        # end
      end
    end


    #
    # Datastream Management
    #
    
    # Returns all known datastreams for the object.  If the object has been 
    # saved to fedora, the persisted datastreams will be included.
    # Datastreams that have been modified in memory are given preference over 
    # the copy in Fedora.
    def datastreams
      if @new_object
        @datastreams = datastreams_in_memory
      else
        @datastreams = (@datastreams == {}) ? datastreams_in_fedora : datastreams_in_memory
        #@datastreams = datastreams_in_fedora.merge(datastreams_in_memory)
      end

    end

    def datastreams_in_fedora #:nodoc:
      mds = {}
      self.datastreams_xml['datastream'].each do |ds|
        ds.merge!({:pid => self.pid, :dsID => ds["dsid"], :dsLabel => ds["label"]})
        if ds["dsid"] == "RELS-EXT" 
          mds.merge!({ds["dsid"] => ActiveFedora::RelsExtDatastream.new(ds)})
        else
          mds.merge!({ds["dsid"] => ActiveFedora::Datastream.new(ds)})
        end
        mds[ds["dsid"]].new_object = false
      end
      mds
    end

    def datastreams_in_memory #:ndoc:
      @datastreams ||= Hash.new
    end

    #return the datastream xml representation direclty from Fedora
    def datastreams_xml
      datastreams_xml = XmlSimple.xml_in(Fedora::Repository.instance.fetch_custom(self.pid, :datastreams))
    end

    # Adds datastream to the object.  Saves the datastream to fedora upon adding.
    # If datastream does not have a DSID, a unique DSID is generated
    # :prefix option will set the prefix on auto-generated DSID
    # @returns DSID of the added datastream
    def add_datastream(datastream, opts={})
      datastream.pid = self.pid
      if datastream.dsid == nil || datastream.dsid.empty?
        prefix = opts.has_key?(:prefix) ? opts[:prefix] : "DS"
        datastream.dsid = generate_dsid(prefix)
      end
      datastreams[datastream.dsid] = datastream
      return datastream.dsid
    end
    def add(datastream) # :nodoc:
      warn "Warning: ActiveFedora::Base.add has been deprected.  Use add_datastream"
      add_datastream(datastream)
    end
    
    #return all datastreams of type ActiveFedora::MetadataDatastream
    def metadata_streams
      results = []
      datastreams.each_value do |ds|
        if ds.kind_of?(ActiveFedora::MetadataDatastream) || ds.kind_of?(ActiveFedora::NokogiriDatastream)
          results<<ds
        end
      end
      return results
    end
    
    #return all datastreams not of type ActiveFedora::MetadataDatastream 
    #(that aren't Dublin Core or RELS-EXT streams either)
    def file_streams
      results = []
      datastreams.each_value do |ds|
        if !ds.kind_of?(ActiveFedora::MetadataDatastream) 
          dsid = ds.dsid
          if dsid != "DC" && dsid != "RELS-EXT"
            results<<ds
          end
        end
      end
      return results
    end
    
    # return a valid dsid that is not currently in use.  Uses a prefix (default "DS") and an auto-incrementing integer
    # Example: if there are already datastreams with IDs DS1 and DS2, this method will return DS3.  If you specify FOO as the prefix, it will return FOO1.
    def generate_dsid(prefix="DS")
      keys = datastreams.keys
      next_index = keys.select {|v| v =~ /(#{prefix}\d*$)/}.length + 1
      new_dsid = prefix.to_s + next_index.to_s
      # while keys.include?(new_dsid)
      #         next_index += 1
      #         new_dsid = prefix.to_s + rand(range).to_s
      #       end
    end
    
    # Return the Dublin Core (DC) Datastream. You can also get at this via 
    # the +datastreams["DC"]+.
    def dc
      #dc = REXML::Document.new(datastreams["DC"].content)
      return  datastreams["DC"] 
    end

    # Returns the RELS-EXT Datastream
    # Tries to grab from in-memory datastreams first
    # Failing that, attempts to load from Fedora and addst to in-memory datastreams
    # Failing that, creates a new RelsExtDatastream and adds it to the object
    def rels_ext
      if !datastreams.has_key?("RELS-EXT") 
        add_datastream(ActiveFedora::RelsExtDatastream.new)
      end
      return datastreams["RELS-EXT"]
    end

    #
    # File Management
    #
    
    def add_file_datastream(file, opts={})
      label = opts.has_key?(:label) ? opts[:label] : ""
      ds = ActiveFedora::Datastream.new(:dsLabel => label, :controlGroup => 'M', :blob => file)
      opts.has_key?(:dsid) ? ds.dsid=(opts[:dsid]) : nil
      add_datastream(ds)
    end
    
    def file_objects
      cm_array = collection_members
      parts_array = parts
      unless cm_array.empty?
        logger.warn "This object has collection member assertions.  hasCollectionMember will no longer be used to track file_object relationships after active_fedora 1.3.  Use isPartOf assertions in the RELS-EXT of child objects instead."
      end
      ary = cm_array+parts_array
      return ary.uniq
    end
    
    def file_objects_append(obj)
      # collection_members_append(obj)
      unless obj.kind_of? ActiveFedora::Base
        begin
          obj = ActiveFedora::Base.load_instance(obj)
        rescue "You must provide either an ActiveFedora object or a valid pid to add it as a file object.  You submitted #{obj.inspect}"
        end
      end
      obj.add_relationship(:is_part_of, self)
    end
    
    # returns an array of all objects that either point to this object with isPartOf or are pointed at by this object using hasPart
    def parts
      parts_array = parts_inbound + parts_outbound
      return parts_array.uniq
    end
    
    def collection_members_append(obj)
      add_relationship(:has_collection_member, obj)
    end

    def collection_members_remove()
      # will rely on SemanticNode.remove_relationship once it is implemented
    end
    
    #
    # Named Datastreams management
    #
    def datastream_names
      named_datastreams_desc.keys
    end
    
    def add_named_file_datastream(name, file, opts={})
      opts.merge!({:blob=>file,:controlGroup=>'M'})
      add_named_datastream(name,opts)
    end

    # Creates a datastream with values 
    def add_named_datastream(name,opts={})
      
      unless named_datastreams_desc.has_key?(name) && named_datastreams_desc[name].has_key?(:type) 
        raise "Failed to add datastream. Named datastream #{name} not defined for object #{pid}." 
      end
      opts.merge!(named_datastreams_desc[name])
        
      label = opts.has_key?(:label) ? opts[:label] : ""

      #only do these steps for managed datastreams
      unless (opts.has_key?(:controlGroup)&&opts[:controlGroup]!="M")
        if opts.has_key?(:file)
          opts.merge!({:blob => opts[:file]}) 
          opts.delete(:file)
        end
        
        raise "You must define parameter blob for this managed datastream to load for #{pid}" unless opts.has_key?(:blob)
        
        #if no explicit label and is a file use original file name for label
        if !opts.has_key?(:label)&&opts[:blob].respond_to?(:original_filename)
          label = opts[:blob].original_filename
        end
        
        if opts[:blob].respond_to?(:content_type)&&!opts[:blob].content_type.nil? && !opts.has_key?(:content_type)
          opts.merge!({:content_type=>opts[:blob].content_type})
        end
     
        raise "The blob must respond to content_type or the hash must have :content_type property set" unless opts.has_key?(:content_type)
        
        #throw error for mimeType mismatch
        if named_datastreams_desc[name].has_key?(:mimeType) && !named_datastreams_desc[name][:mimeType].eql?(opts[:content_type])
          raise "Content type mismatch for add datastream #{name} to #{pid}.  Expected: #{named_datastreams_desc[name][:mimeType]}, Actual: #{opts[:content_type]}"
        end
      else 
        label = opts[:dsLocation] if (opts.has_key?(:dsLocation)) 
      end
      
      opts.merge!(:dsLabel => label)
      
      #make sure both dsid and dsID populated if a dsid is supplied
      opts.merge!(:dsid=>opts[:dsID]) if opts.has_key?(:dsID)
      opts.merge!(:dsID=>opts[:dsid]) if opts.has_key?(:dsid)
      
      ds = create_datastream(named_datastreams_desc[name][:type],opts)
      #Must be of type datastream
      assert_kind_of 'datastream',  ds, ActiveFedora::Datastream
      #make sure dsid is nil so that it uses the prefix for mapping purposes
      #check dsid works for the prefix if it is set
      if !ds.dsid.nil? && opts.has_key?(:prefix)
        raise "dsid supplied does not conform to pattern #{opts[:prefix]}[number]" unless ds.dsid =~ /#{opts[:prefix]}[0-9]/
      end
      
      add_datastream(ds,opts)
    end

    ########################################################################
    ### TODO: Currently requires you to update file if a managed datastream
    ##        but could change to allow metadata only updates as well
    ########################################################################
    def update_named_datastream(name, opts={})
      #check that dsid provided matches existing datastream with that name
      raise "You must define parameter dsid for datastream to update for #{pid}" unless opts.include?(:dsid)
      raise "Datastream with name #{name} and dsid #{opts[:dsid]} does not exist for #{pid}" unless self.send("#{name}_ids").include?(opts[:dsid])
      add_named_datastream(name,opts)
    end
    
    def assert_kind_of(n, o,t)
      raise "Assertion failure: #{n}: #{o} is not of type #{t}" unless o.kind_of?(t)
    end
    
    def is_named_datastream?(name)
      named_datastreams_desc.has_key?(name)
    end

    def named_datastreams
      ds_values = {}
      self.class.named_datastreams_desc.keys.each do |name|
        ds_values.merge!({name=>self.send("#{name}")})
      end
      return ds_values
    end
    
    def named_datastreams_attributes
      ds_values = {}
      self.class.named_datastreams_desc.keys.each do |name|
        ds_array = self.send("#{name}")
        result_hash = {}
        ds_array.each do |ds|
          result_hash[ds.dsid]=ds.attributes
        end
        ds_values.merge!({name=>result_hash})
      end
      return ds_values
    end
    
    def named_datastreams_ids
      dsids = {}
      self.class.named_datastreams_desc.keys.each do |name|
        dsid_array = self.send("#{name}_ids")
        dsids[name] = dsid_array
      end
      return dsids
    end 
    
    def datastreams_attributes
      ds_values = {}
      self.datastreams.each_pair do |dsid,ds|
        ds_values.merge!({dsid=>ds.attributes})
      end
      return ds_values
    end
    
    def named_datastreams_desc
      @named_datastreams_desc ||= named_datastreams_desc_from_class
    end
    
    def named_datastreams_desc_from_class
      self.class.named_datastreams_desc
    end
    
    def create_datastream(type,opts={})
      type.to_s.split('::').inject(Kernel) {|scope, const_name| 
      scope.const_get(const_name)}.new(opts)
    end

    def self.has_datastream(args)
      unless args.has_key?(:name)
        return false
      end
      unless args.has_key?(:prefix)
        args.merge!({:prefix=>args[:name].to_s.upcase})
      end
      unless named_datastreams_desc.has_key?(args[:name]) 
        named_datastreams_desc[args[:name]] = {} 
      end
          
      args.merge!({:mimeType=>args[:mime_type]}) if args.has_key?(:mime_type)
      
      unless named_datastreams_desc[args[:name]].has_key?(:type) 
        #default to type ActiveFedora::Datastream
        args.merge!({:type => "ActiveFedora::Datastream"})
      end
      named_datastreams_desc[args[:name]]= args   
      create_named_datastream_finders(args[:name],args[:prefix])
      create_named_datastream_update_methods(args[:name])
    end
        
    def self.create_named_datastream_update_methods(name)
      append_file_method_name = "#{name.to_s.downcase}_file_append"
      append_method_name = "#{name.to_s.downcase}_append"
      #remove_method_name = "#{name.to_s.downcase}_remove"
      self.send(:define_method,:"#{append_file_method_name}") do |*args| 
        file,opts = *args
        opts ||= {}
        add_named_file_datastream(name,file,opts)
      end
      
      self.send(:define_method,:"#{append_method_name}") do |*args| 
        opts = *args
        opts ||= {}
        #call add_named_datastream instead of add_file_named_datastream in case not managed datastream
        add_named_datastream(name,opts)
      end
    end 
        
    def self.create_named_datastream_finders(name, prefix)
      class_eval <<-END
      def #{name}(opts={})
        id_array = []
        keys = datastreams.keys
        id_array = keys.select {|v| v =~ /#{prefix}\d*/}
        if opts[:response_format] == :id_array
          return id_array
        else
          named_ds = []
          id_array.each do |name|
            if datastreams.has_key?(name)
              named_ds.push(datastreams[name])
            end
          end
          return named_ds
        end
      end
      def #{name}_ids
        #{name}(:response_format => :id_array)
      end
      END
    end
        
    # named datastreams desc are tracked as a hash of structure {name => args}}
    def self.named_datastreams_desc
      @class_named_datastreams_desc ||= {}
    end

    # 
    # Relationships Management
    #
    
    # @returns Hash of relationships, as defined by SemanticNode
    # Rely on rels_ext datastream to track relationships array
    # Overrides accessor for relationships array used by SemanticNode.
    # If outbound_only is false, inbound relationships will be included.
    def relationships(outbound_only=true)
      outbound_only ? rels_ext.relationships : rels_ext.relationships.merge(:inbound=>inbound_relationships)
    end

    # Add a Rels-Ext relationship to the Object.
    # @param predicate
    # @param object Either a string URI or an object that responds to .pid 
    def add_relationship(predicate, obj)
      r = ActiveFedora::Relationship.new(:subject=>:self, :predicate=>predicate, :object=>obj)
      unless relationship_exists?(r.subject, r.predicate, r.object)
        rels_ext.add_relationship(r)
        #need to call here to indicate update of named_relationships
        @relationships_are_dirty = true
        rels_ext.dirty = true
      end
    end
    
    def remove_relationship(predicate, obj)
      r = ActiveFedora::Relationship.new(:subject=>:self, :predicate=>predicate, :object=>obj)
      rels_ext.remove_relationship(r)
      #need to call here to indicate update of named_relationships
      @relationships_are_dirty = true
      rels_ext.dirty = true
    end

    def inner_object # :nodoc
      @inner_object
    end

    #return the pid of the Fedora Object
    def pid
      @inner_object.pid
    end
    
    #For Rails compatibility with url generators.
    def to_param
      self.pid
    end
    #return the internal fedora URI
    def internal_uri
      "info:fedora/#{pid}"
    end
    
    #return the state of the inner object
    def state 
      @inner_object.state
    end

    #return the owner id
    def owner_id
      @inner_object.owner_id
    end
    
    def owner_id=(owner_id)
      @inner_object.owner_id=(owner_id)
    end

    #return the create_date of the inner object (unless it's a new object)
    def create_date
      @inner_object.create_date unless new_object?
    end

    #return the modification date of the inner object (unless it's a new object)
    def modified_date
      @inner_object.modified_date unless new_object?
    end

    #return the error list of the inner object (unless it's a new object)
    def errors
      @inner_object.errors
    end
    
    #return the label of the inner object (unless it's a new object)
    def label
      @inner_object.label
    end
    
    def label=(new_label)
      @inner_object.label = new_label
    end


    def self.deserialize(doc) #:nodoc:
      if doc.instance_of?(REXML::Document)
        pid = doc.elements['/foxml:digitalObject'].attributes['PID']
      
        proto = self.new(:pid=>pid, :new_object=>false)
        proto.datastreams.each do |name,ds|
          doc.elements.each("//foxml:datastream[@ID='#{name}']") do |el|
            # datastreams remain marked as new if the foxml doesn't have an entry for that datastream
            ds.new_object = false
            proto.datastreams[name]=ds.class.from_xml(ds, el)          
          end
        end
        proto.inner_object.new_object = false
        return proto
      elsif doc.instance_of?(Nokogiri::XML::Document)
        pid = doc.xpath('/foxml:digitalObject').first["PID"]
      
        proto = self.new(:pid=>pid, :new_object=>false)
        proto.datastreams.each do |name,ds|
          doc.xpath("//foxml:datastream[@ID='#{name}']").each do |node|
            # datastreams remain marked as new if the foxml doesn't have an entry for that datastream
            ds.new_object = false
            # Nokogiri Datstreams use a new syntax for .from_xml (tmpl is optional!) and expects the actual xml content rather than the foxml datstream xml
            # NB: Base.deserialize, or a separately named method, should set any other info from the foxml if necessary though by this point it's all been grabbed elsewhere... 
            if ds.kind_of?(ActiveFedora::NokogiriDatastream) 
              xml_content = Fedora::Repository.instance.fetch_custom(pid, "datastreams/#{name}/content")
              # node = node.search('./foxml:datastreamVersion[last()]/foxml:xmlContent/*').first
              proto.datastreams[name]=ds.class.from_xml(xml_content, ds)
            else
              proto.datastreams[name]=ds.class.from_xml(ds, node)          
            end
          end
        end
        proto.inner_object.new_object = false
        return proto
      end
    end

    #Return a hash of all available metadata fields for all 
    #ActiveFedora::MetadataDatastream datastreams, as well as 
    #system_create_date, system_modified_date, active_fedora_model_field, 
    #and the object id.
    def fields
      fields = {:id => {:values => [pid]}, :system_create_date => {:values => [self.create_date], :type=>:date}, :system_modified_date => {:values => [self.modified_date], :type=>:date}, :active_fedora_model => {:values => [self.class.inspect], :type=>:symbol}}
      datastreams.values.each do |ds|        
        fields.merge!(ds.fields) if ds.kind_of?(ActiveFedora::MetadataDatastream)
      end
      return fields
    end
    
    #Returns the xml version of this object as a string.
    def to_xml(xml=Nokogiri::XML::Document.parse("<xml><fields/><content/></xml>"))
      fields_xml = xml.xpath('//fields').first
      builder = Nokogiri::XML::Builder.with(fields_xml) do |fields_xml|
        fields_xml.id_ pid
        fields_xml.system_create_date self.create_date
        fields_xml.system_modified_date self.modified_date
        fields_xml.active_fedora_model self.class.inspect
      end
      
      # {:id => pid, :system_create_date => self.create_date, :system_modified_date => self.modified_date, :active_fedora_model => self.class.inspect}.each_pair do |attribute_name, value|
      #   el = REXML::Element.new(attribute_name.to_s)
      #   el.text = value
      #   fields_xml << el
      # end
      
      datastreams.each_value do |ds|  
        ds.to_xml(fields_xml) if ds.class.included_modules.include?(ActiveFedora::MetadataDatastreamHelper) || ds.kind_of?(ActiveFedora::RelsExtDatastream)
      end
      return xml.to_s
    end

    # Return a Solr::Document version of this object.
    # @solr_doc (optional) Solr::Document to insert the fields into
    # @opts (optional) Hash
    # If opts[:model_only] == true, the base object metadata and the RELS-EXT datastream will be omitted.  This is mainly to support shelver, which calls .to_solr for each model an object subscribes to. 
    def to_solr(solr_doc = Solr::Document.new, opts={})
      unless opts[:model_only]
        solr_doc << {SOLR_DOCUMENT_ID.to_sym => pid, solr_name(:system_create, :date) => self.create_date, solr_name(:system_modified, :date) => self.modified_date, solr_name(:active_fedora_model, :symbol) => self.class.inspect}
      end
      datastreams.each_value do |ds|
        # solr_doc = ds.to_solr(solr_doc) if ds.class.included_modules.include?(ActiveFedora::MetadataDatastreamHelper) ||( ds.kind_of?(ActiveFedora::RelsExtDatastream) || ( ds.kind_of?(ActiveFedora::QualifiedDublinCoreDatastream) && !opts[:model_only] )
        solr_doc = ds.to_solr(solr_doc) if ds.kind_of?(ActiveFedora::MetadataDatastream) || ds.kind_of?(ActiveFedora::NokogiriDatastream) || ( ds.kind_of?(ActiveFedora::RelsExtDatastream) && !opts[:model_only] )
      end
      begin
        #logger.info("PID: '#{pid}' solr_doc put into solr: #{solr_doc.inspect}")
      rescue
        logger.info("Error encountered trying to output solr_doc details for pid: #{pid}")
      end
      return solr_doc
    end
    
    ###########################################################################################################
    #
    # This method is comparable to load_instance except it populates an object from Solr instead of Fedora.
    # It is most useful for objects used in read-only displays in order to speed up loading time.  If only
    # a pid is passed in it will attempt to load a solr document and then populate an ActiveFedora::Base object
    # based on the solr doc including any metadata datastreams and relationships.
    # 
    # solr_doc is an optional parameter and if a value is passed it will not query solr again and just use the
    # one passed to populate the object.
    #
    ###########################################################################################################
    def self.load_instance_from_solr(pid,solr_doc=nil)
      if solr_doc.nil?
        result = find_by_solr(pid)
        raise "Object #{pid} not found in solr" if result.nil?
        solr_doc = result.hits.first
        #double check pid and id in record match
        raise "Object #{pid} not found in Solr" unless !result.nil? && !solr_doc.nil? && pid == solr_doc[SOLR_DOCUMENT_ID]
      else
       raise "Solr document record id and pid do not match" unless pid == solr_doc[SOLR_DOCUMENT_ID]
     end
     
      create_date = solr_doc[Solrizer::FieldNameMapper.solr_name(:system_create, :date)].nil? ? solr_doc[Solrizer::FieldNameMapper.solr_name(:system_create, :date).to_s] : solr_doc[Solrizer::FieldNameMapper.solr_name(:system_create, :date)]
      modified_date = solr_doc[Solrizer::FieldNameMapper.solr_name(:system_create, :date)].nil? ? solr_doc[Solrizer::FieldNameMapper.solr_name(:system_modified, :date).to_s] : solr_doc[Solrizer::FieldNameMapper.solr_name(:system_modified, :date)]
      obj = self.new({:pid=>solr_doc[SOLR_DOCUMENT_ID],:create_date=>create_date,:modified_date=>modified_date})
      obj.new_object = false
      #set by default to load any dependent relationship objects from solr as well
      obj.load_from_solr = true
      #need to call rels_ext once so it exists when iterating over datastreams
      obj.rels_ext
      obj.datastreams.each_value do |ds|
        if ds.respond_to? (:from_solr)
          ds.from_solr(solr_doc) if ds.kind_of?(ActiveFedora::MetadataDatastream) || ds.kind_of?(ActiveFedora::NokogiriDatastream) || ( ds.kind_of?(ActiveFedora::RelsExtDatastream))
        end
      end
      obj
    end

    # Updates Solr index with self.
    def update_index
      if defined?( Solrizer::Solrizer ) 
        #logger.info("Trying to solrize pid: #{pid}")
        solrizer = Solrizer::Solrizer.new
        solrizer.solrize( self )
      else
        #logger.info("Trying to update solr for pid: #{pid}")
        SolrService.instance.conn.update(self.to_solr)
      end
    end

    # An ActiveRecord-ism to udpate metadata values.
    #
    # Example Usage:
    #
    # m.update_attributes(:fubar=>'baz')
    #
    # This will attempt to set the values for any fields named fubar in any of 
    # the object's datastreams. This means DS1.fubar_values and DS2.fubar_values 
    # are _both_ overwritten.  
    #
    # If you want to specify which datastream(s) to update,
    # use the :datastreams argument like so:
    #  m.update_attributes({:fubar=>'baz'}, :datastreams=>"my_ds")
    # or
    #  m.update_attributes({:fubar=>'baz'}, :datastreams=>["my_ds", "my_other_ds"])
    def update_attributes(params={}, opts={})
      result = {}
      if opts[:datastreams]
        ds_array = []
        opts[:datastreams].each do |dsname|
          ds_array << datastreams[dsname]
        end
      else
        ds_array = metadata_streams
      end
      ds_array.each do |d|
        ds_result = d.update_attributes(params,opts)
        result[d.dsid] = ds_result
      end
      return result
    end

    # A convenience method  for updating indexed attributes.  The passed in hash
    # must look like this : 
    #   {{:name=>{"0"=>"a","1"=>"b"}}
    #
    # This will result in any datastream field of name :name having the value [a,b]
    #
    # An index of -1 will insert a new value. any existing value at the relevant index 
    # will be overwritten.
    #
    # As in update_attributes, this overwrites _all_ available fields by default.
    #
    # If you want to specify which datastream(s) to update,
    # use the :datastreams argument like so:
    #  m.update_attributes({"fubar"=>{"-1"=>"mork", "0"=>"york", "1"=>"mangle"}}, :datastreams=>"my_ds")
    # or
    #  m.update_attributes({"fubar"=>{"-1"=>"mork", "0"=>"york", "1"=>"mangle"}}, :datastreams=>["my_ds", "my_other_ds"])
    #
    def update_indexed_attributes(params={}, opts={})
      if opts[:datastreams]
        ds_array = []
        opts[:datastreams].each do |dsname|
          ds_array << datastreams[dsname]
        end
      else
        ds_array = metadata_streams
      end
      result = {}
      ds_array.each do |d|
        result[d.dsid] = d.update_indexed_attributes(params,opts)
      end
      return result
    end
    
    def update_datastream_attributes(params={}, opts={})
      result = params.dup
      params.each_pair do |dsid, ds_params| 
        if datastreams_in_memory.include?(dsid)
          result[dsid] = datastreams_in_memory[dsid].update_attributes(ds_params)
        else
          result.delete(dsid)
        end
      end
      return result
    end
    
    def get_values_from_datastream(dsid,field_key,default=[])
      if datastreams_in_memory.include?(dsid)
        return datastreams_in_memory[dsid].get_values(field_key,default)
      else
        return nil
      end
    end
    
    def self.pids_from_uris(uris) 
      if uris.class == String
        return uris.gsub("info:fedora/", "")
      elsif uris.class == Array
        arr = []
        uris.each do |uri|
          arr << uri.gsub("info:fedora/", "")
        end
        return arr
      end
    end
    
    def logger      
      @logger ||= defined?(RAILS_DEFAULT_LOGGER) ? RAILS_DEFAULT_LOGGER : Logger.new(STDOUT)
    end
    
    private
    def configure_defined_datastreams
      if self.class.ds_specs
        self.class.ds_specs.each do |name,ar|
          if self.datastreams.has_key?(name)
            attributes = self.datastreams[name].attributes
          else
            attributes = {:label=>""}
          end
          ds = ar.first.new(:dsid=>name)
          # If you called has_metadata with a block, pass the block into the Datastream class
          if ar.last.class == Proc
            ar.last.call(ds)
          end
          ds.attributes = attributes.merge(ds.attributes)
          self.add_datastream(ds)
        end
      end
    end
    
    # Deals with preparing new object to be saved to Fedora, then pushes it and its datastreams into Fedora. 
    def create
      add_relationship(:has_model, ActiveFedora::ContentModel.pid_from_ruby_class(self.class))
      @metadata_is_dirty = true
      update
      #@datastreams = datastreams_in_fedora
    end
    
    # Pushes the object and all of its new or dirty datastreams into Fedora
    def update
      result = Fedora::Repository.instance.save(@inner_object)      
      datastreams_in_memory.each do |k,ds|
        if ds.dirty? || ds.new_object? 
          if ds.class.included_modules.include?(ActiveFedora::MetadataDatastreamHelper) || ds.instance_of?(ActiveFedora::RelsExtDatastream)
          # if ds.kind_of?(ActiveFedora::MetadataDatastream) || ds.kind_of?(ActiveFedora::NokogiriDatastream) || ds.instance_of?(ActiveFedora::RelsExtDatastream)
            @metadata_is_dirty = true
          end
          result = ds.save
        end 
      end
      refresh
      return result
    end

  end
end
