require_relative 'ldap/converters'
require_relative 'ldap/extensions'
require_relative 'filtered'

class LOM
using LDAP::Extensions
using LDAP::Converters    

# This module is to be prepend to Entry instance when processing
# block `from_ldap`
#
# It will allow the use of refined methods #first, #[], #all
# without requiring an explicit import of LDAPExt refinement
# in the class being mapped.
#
module EntryEnhanced
    def first(*args) ; super ; end
    def [](*args)    ; super ; end
    alias :all :[]
end



# Instance methods to be injected in the class being mapped.
#
module Mapper
module InstanceMethods
    # LDAP handler
    def lh
        self.class.lh
    end

    # Save object to ldap.
    #
    # If object already exists, it will be updated otherwise created.
    #
    # @return [true, false]
    #
    def save!
        model  = self.class
        attrs  = instance_exec(self, &model.ldap_to)
                     .transform_values {|v|
                          # Don't use Array(), not what you think on
                          # some classes such as Time
                          v = [   ] if     v.nil? 
                          v = [ v ] unless v.is_a?(Array)
                          v.to_ldap
                     }
        id, _  = Array(attrs[model.ldap_prefix])
        raise MappingError, 'prefix for dn has multiple values' if _
        dn     = model.ldap_dn_from_id(id)
        
        lh.update(dn: dn, attributes: attrs).then {|res|
            break res unless res.nil?
            attrs.reject! {|k, v| Array(v).empty? }
            lh.add(dn: dn, attributes: attrs)
        }
    end
end
end



# Class methods to be injected in the class being mapped,
# and performs initialization thanks to #extend_object
#
module Mapper
    def self.extend_object(o)
        super
        o.include Mapper::InstanceMethods
        o.extend  Enumerable
        o.const_set(:Filtered, LOM::Filtered)
        o.__ldap_init
    end

    def __ldap_init
        @__ldap_branch    = nil
        @__ldap_prefix    = nil
        @__ldap_scope     = :one
        @__ldap_filter    = nil
        @__ldap_attrs     = nil
        @__ldap_from      = nil
        @__ldap_to        = nil
        @__ldap_list      = []
        @__ldap_lh        = nil
    end

    # Get the LDAP handler to use
    #
    # In order of preference:
    #
    # * the handler set using lh=
    # * the LH constant in this scope or parent scope
    # * the one provided by LOM.lh
    #
    def lh
        @__ldap_lh || const_get(:LH) || LOM.lh
    end

    # Set the LDAP handler to use
    def lh=(lh)
        @__ldap_lh = lh
    end
        
    # Return the list of defined list (using ldap_list).
    #
    # @return [Array<Symbol>] list of defined ldap list
    #
    def ldap_listing
        @__ldap_list
    end

    def ldap_list(name, body=nil, &block)
        if body && block
            raise ArgumentError
        elsif body.nil? && block.nil?
            raise ArgumentError
        elsif block
            body = block
        end
            
        @__ldap_list << name
        define_singleton_method(name) do |*args|
            filter = body.call(*args)
            LOM::Filtered.new(filter, src: self)
        end
    end

    
    def ldap_branch(v = nil)
        return _ldap_branch if v.nil?
        @__ldap_branch = v
    end
    
    def ldap_prefix(v = nil)
        return _ldap_prefix if v.nil?
        @__ldap_prefix = v
    end
    
    def ldap_scope(v)
        @__ldap_scope = v
    end
    
    def ldap_filter(v)
        @__ldap_filter = v[0] == '(' ? v : "(#{v})"
    end
    
    def ldap_attrs(*v)
        @__ldap_attrs = v
    end

    # @note block will be executed in the Net::LDAP::Entry instance
    def ldap_from(p=nil, &b)
        if (! p.nil? ^ b.nil?) || (p && !p.kind_of?(Proc))
            raise ArgumentError,
                  'one and only one of proc/lamba/block need to be defined'
        end
        @__ldap_from = p || b
    end

    # @note block will be executed in the mapped object instance
    def ldap_to(p=nil, &b)
        return _ldap_to if p.nil? && b.nil?

        if (! p.nil? ^ b.nil?) || (p && !p.kind_of?(Proc))
            raise ArgumentError,
                  'one and only one of proc/lamba/block need to be defined'
        end
        @__ldap_to = p || b
    end


    # Convert a dn to it's corresponding id the current mapping.
    #
    # @raise [Error]   dn belongs to this mapping (it is in the mapping
    #                  branch), but is malformed (not a direct child, or
    #                  wrong prefix)
    #
    # @return [String] id
    # @return [nil]    dn is not from this mapping
    #
    def ldap_dn_to_id(dn)
        prefix = _ldap_prefix.to_s
        branch = _ldap_branch
        
        if sub = Net::LDAP::DN.sub?(dn, branch)
            case prefix
            when String, Symbol
                k, v, _ = sub.to_a
                raise Error, "not a direct child" if _
                raise Error, "wrong prefix"       if k.casecmp(prefix) != 0
                v
            end
        end
    end
    
    def ldap_dn_from_id(id)
        Net::LDAP::DN.new(_ldap_prefix.to_s, id, _ldap_branch).to_s
    end

    def _ldap_to_obj(entry)
        raise EntryNotFound if entry.nil?
        entry.extend(EntryEnhanced)       
        args  = entry.instance_exec(entry, &_ldap_from)
        args  = [ args ] unless args.kind_of?(Array)
        self.new(*args)
    end
    

    # Iterate over matching data.
    #
    # @note If using `rawfilter`, no optimization will be performed
    #       aned the ldap attributes will be retrieved,
    #       even if desired type is :id
    #
    # @param type      [:object, :id]           return object or id
    # @param filter    [String]                 extra ldap search filter
    # @param rawfilter [Proc]                   filter on ldap entry
    # @param paged     [Array<Integer,Integer>] pagination information
    #
    # @yieldparam obj_or_id [Object, String] ldap converted element according to type
    #
    # @return [Enumerator] if no block given
    # @return [self]       if block given
    #
    def each(type = :object, filter: nil, rawfilter: nil, paged: nil)
        # Create Enumerator if no block given
        unless block_given?
            return enum_for(:each, type,
                            filter: filter, rawfilter: rawfilter, paged: paged)
        end

        # Merging filters
        filter  = Net::LDAP.filter('&', *[ filter, _ldap_filter ].compact)

        # Define attributes/converter according to selected type
        attributes, converter =
            case type
            when :id     then [ rawfilter ? _ldap_attrs : :dn,
                                ->(e) { ldap_dn_to_id(e.dn) }
                              ]
            when :object then [ _ldap_attrs,
                                ->(e) { _ldap_to_obj(e)     }
                              ]
            else raise ArgumentError, 'type must be either :object or :id'
            end

        
        # Paginate
        # XXX: pagination is emulated, should be avoided
        skip, count = if paged
                          page, page_size = paged
                          [ (page - 1) * page_size, page_size ]
                      end
        
        # Perform search
        lh.search(:base       => _ldap_branch,
                  :filter     => filter,
                  :attributes => attributes,
                  :scope      => _ldap_scope) {|entry|

            if rawfilter && !rawfilter.call(entry)
                next
            elsif paged.nil?
                yield(converter.(entry))
            elsif skip > 0
                skip -= 1
            elsif count <= 0
                break
            else
                count -= 1
                yield(converter.(entry))
            end                
        }

        # Return self
        self
    end

    def paginate(page, page_size)
        LOM::Filtered.new(src: self, paged: [ page, page_size ])
    end
  
    # Retrieve matching data as a list of object
    #
    # @return [Array<Object>]
    #
    def all(&rawfilter)
        each(:object, rawfilter: rawfilter).to_a
    end

    # Retrieve matching data as a list of id
    #
    # @return [Array<String>]
    #
    def list(&rawfilter)
        each(:id, rawfilter: rawfilter).to_a
    end

    # Fetch the requested entry.
    #
    # @param param [String]  entry name
    #
    # @raise [LOM::EntryNotFound] if entry not found
    #
    # @return [Object]
    #
    def fetch(name)
        dn    = ldap_dn_from_id(name)
        attrs = _ldap_attrs
        entry = lh.get(:dn => dn, :attributes => attrs)

        _ldap_to_obj(entry)
    end

    def delete!(name)
        dn    = ldap_dn_from_id(name)
        lh.delete(:dn => dn)
    end

    # Get the requested entry.
    # Same as #fetch but return nil if not found
    #
    # @param param [String]  entry name
    #
    # @return [nil] entry not found
    # @return [Object]
    #
    def get(name)
        fetch(name)
    rescue LOM::EntryNotFound
        nil
    end

    alias [] get

    # Test existence of entry
    #
    # @param param [String]  entry name
    #
    # @return [Boolean]
    #
    def exists?(name)
        dn    = ldap_dn_from_id(name)
        lh.get(:dn => dn, :return_result => false)
    end

    private
    
    def _ldap_branch
        @__ldap_branch || (raise MappingError, 'ldap_branch not defined')
    end

    def _ldap_prefix
        @__ldap_prefix || (raise MappingError, 'ldap_prefix not defined')
    end

    def _ldap_scope
        @__ldap_scope
    end

    def _ldap_filter
        @__ldap_filter
    end

    def _ldap_attrs
        @__ldap_attrs
    end

    def _ldap_from
        @__ldap_from   || (raise MappingError, 'ldap_from not defined'  )
    end

    def _ldap_to
        @__ldap_to     || (raise MappingError, 'ldap_to not defined'    )
    end

end
end
