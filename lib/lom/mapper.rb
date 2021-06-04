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
        attrs  = instance_exec(self, &self.class._ldap_to)
                     .transform_values {|v|
                          # Don't use Array(), not what you think on
                          # some classes such as Time
                          v = [   ] if     v.nil? 
                          v = [ v ] unless v.is_a?(Array)
                          v.to_ldap
                     }
        id, _  = Array(attrs[self.class._ldap_prefix])
        raise MappingError, 'prefix for dn has multiple values' if _
        dn     = self.class.ldap_dn_from_id(id)
        
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

    
    def ldap_branch(v)
        @__ldap_branch = v
    end
    
    def ldap_prefix(v)
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
        if (! p.nil? ^ b.nil?) || (p && !p.kind_of?(Proc))
            raise ArgumentError,
                  'one and only one of proc/lamba/block need to be defined'
        end
        @__ldap_to = p || b
    end


    
    def ldap_dn_to_id(dn)
        prefix = _ldap_prefix.to_s
        branch = _ldap_branch
        
        if sub = Net::LDAP::DN.sub?(dn, branch)
            case prefix
            when String, Symbol
                k, v, _ = sub.to_a
                raise ArgumentError, "not a direct child" if _
                raise ArgumentError, "wrong prefix"       if k.casecmp(prefix) != 0
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
    
    
    def each(type = :object, filter: nil, paged: nil)
        # Create Enumerator if no block given
        unless block_given?
            return enum_for(:each, type, filter: filter, paged: paged)
        end

        # Merging filters
        filters = [ filter, _ldap_filter ].compact
        filter  = filters.size == 2 ? "(&#{filters.join})" : filters.first

        # Define attributes/converter according to selected type
        attributes, converter =
            case type
            when :id     then [ :dn,         ->(e) { ldap_dn_to_id(e.dn) } ]
            when :object then [ _ldap_attrs, ->(e) { _ldap_to_obj(e)     } ]
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

            if paged.nil?
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
    end

    def paginate(page, page_size)
        LOM::Filtered.new(src: self, paged: [ page, page_size ])
    end
  
    def all
        each(:object).to_a
    end

    def list
        each(:id).to_a
    end
    
    def get(name)
        dn    = ldap_dn_from_id(name)
        attrs = _ldap_attrs
        entry = lh.get(:dn => dn, :attributes => attrs)

        _ldap_to_obj(entry)
    end

    def delete!(name)
        dn    = ldap_dn_from_id(name)
        lh.delete(:dn => dn)
    end

    alias [] get

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
