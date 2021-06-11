# -*- coding: utf-8 -*-

require 'net/ldap'
require 'net/ldap/dn'

require_relative '../core'


module LOM::LDAP

# Ensure that the Converters module exists.
#
# NOTE: If the optional refinements provided by this modules are required,
#       they need to be defined/loaded before requiring this file
#       For example: require 'lom/ldap/converters'
module Converters
end


# Provide refinements to ease development with the net/ldap library:
#
# * Net::LDAP instance can be created from an URI
#   using Net::LDAP.connect
#
# * Net::LDAP#search can use symbols for
#      scope: :base, :one, :sub
#      deref: :never, :search, :find, :always
#
# * Net::LDAP#get method allows retrieving the first entry of a DN
#   (it is just a customized search query)
#
# * Net::LDAP#update method that try to intelligently update an
#   LDAP attribute (to be used instead of Net::LDAP#modify)
#
# * Net::LDAP::Entry has been enhanced to easy casting of retrieved
#   attributes
#
# * Net::LDAP::DN.sub? has been added to test if a DN is included
#   in another, and will return the sub part
#
# * Net::LDAP::DN.escape and Net::LDAP:Filter.escape have been
#   redefined to fix some issues
#
module Extensions
    refine Net::LDAP.singleton_class  do
        def filter(op, *args)
            op, check = case op
                        when :or,  '|'  then [ '|',  1.. ]
                        when :and, '&'  then [ '&',  1.. ]
                        when :not, '!'  then [ '!',  1   ]
                        when :ge,  '>=' then [ '>=', 2   ]
                        when :eq,  '='  then [ '=',  2   ]
                        when :le,  '<=' then [ '<=', 2   ]
                        else raise ArgumentError, 'Unknown operation'
                        end
            args = args.compact.map(&:strip).reject(&:empty?).map {|a|
                if    ( a[0] == '(' ) && ( a[-1] == ')' ) then a
                elsif ( a[0] != '(' ) && ( a[-1] != ')' ) then "(#{a})"
                else raise ArgumentError, "Bad LDAP filter: #{a}"
                end
            }
            case args.size
            when 0 then nil
            when 1 then args[0]
            else        "(#{op}#{args.join})"
            end
        end

        def connect(uri=nil, **opts)
            if uri
                uri = URI(uri)
                case uri.scheme
                when 'ldap'  then
                when 'ldaps' then opts[:encryption] = :simple_tls
                else raise ArgumentError, "Unsupported protocol #{proto}";
                end
                opts[:host] = uri.host
                opts[:port] = uri.port
            end
            self.new(opts)
        end
    end
    
    refine Net::LDAP do
        def close
        end

        def search(args={}, &block)
            if deref = case args[:deref]
                       when :never  then Net::LDAP::DerefAliases_Never
                       when :search then Net::LDAP::DerefAliases_Search
                       when :find   then Net::LDAP::DerefAliases_Find
                       when :always then Net::LDAP::DerefAliases_Always
                       end
                args[:deref] = deref
            end
            if scope = case args[:scope]
                       when :base   then Net::LDAP::SearchScope_BaseObject
                       when :one    then Net::LDAP::SearchScope_SingleLevel
                       when :sub    then Net::LDAP::SearchScope_WholeSubtree
                       end
                args[:scope] = scope
            end
            super(args, &block)
        end

        def get(dn:, attributes: nil, attributes_only: false,
                return_result: true, time: nil, deref: :never, &block)
            search(:base            => dn,
                   :scope           => :base,
                   :attributes      => attributes,
                   :attributes_only => attributes_only,
                   :return_result   => return_result,
                   :time            => time,
                   :deref           => deref,
                   &block)
                .then {|r| return_result ? r&.first : r }
        end

        # Update an existing dn entry.
        # The necessary operation (add/modify/replace) will be built
        # accordingly.
        #
        # @note the dn can be specified, either in the dn parameter
        #       or as a key in the attributes parameter
        #
        # @param dn
        # @param attributes
        #
        # @return [nil]     dn doesn't exist so it can't be updated
        # @return [Boolean] operation success
        #
        # @raise [ArgumentError] if DN missing or incoherent
        #
        def update(dn: nil, attributes: {})
            # Normalize keys
            attributes = attributes.to_h.dup
            attributes.transform_keys!   {|k| k.downcase.to_sym  }
            attributes.transform_values! {|v| Array(v)           }
            attributes.transform_values! {|v| v.empty? ? nil : v }

            # Sanitize
            _dn = attributes[:dn]
            if _dn && _dn.size > 1
                raise ArgumentError, 'only one DN can be specified'
            end
            if dn.nil? && _dn.nil?
                raise ArgumentError, 'missing DN'
            elsif dn && _dn && dn != _dn.first
                raise ArgumentError, 'attribute DN doesn\'t match provided DN'
            end

            dn              ||= _dn.first
            attributes[:dn]   = [ dn ]
            
            # Retrieve existing attributes
            # Note: dn is always present in entries
            entries = get(dn: dn, attributes: attributes.keys)
            
            # Entry not found
            return nil if entries.nil?

            # Identify keys
            changing = attributes.compact.keys
            removing = attributes.select {|k, v| v.nil? }.keys
            existing = entries.attribute_names
            add      = changing - existing
            modify   = changing & existing 
            delete   = removing & existing 

            # Remove key from update if same content
            modify.reject! {|k| attributes[k] == entries[k] }
                
            # Build operations
            # Note: order is delete/modify/add
            #       to avoid "Object Class Violation" due to possible
            #       modification of objectClass
            ops = []
            ops += delete.map {|k| [ :delete,  k, nil           ] }
            ops += modify.map {|k| [ :replace, k, attributes[k] ] }
            ops += add   .map {|k| [ :add,     k, attributes[k] ] }

            # Apply
            if LOM.debug.include?(:verbose)
                $stderr.puts "Update: #{dn}"
                $stderr.puts ops.inspect
            end
            if LOM.debug.include?(:dry)
                return true
            end
            return true if ops.empty?               # That's a no-op
            modify(:dn => dn, :operations => ops)   # Apply modifications
        end       
    end

    refine Net::LDAP::Filter.singleton_class do
        def escape(str)
            str.gsub(/([\x00-\x1f*()\\])/) { '\\%02x' % $1[0].ord }
        end
    end

    refine Net::LDAP::DN.singleton_class do
        def sub?(dn, prefix)
            _dn     = Net::LDAP::DN.new(dn    ).to_a
            _prefix = Net::LDAP::DN.new(prefix).to_a
            return nil if _dn.size <= _prefix.size
            sub     = _dn[0 .. - (_prefix.size + 1)]
            return nil if sub.empty?
            Net::LDAP::DN.new(*sub)
        end
    end
    
    refine Net::LDAP::DN.singleton_class do
        def escape(str)
            str.gsub(/([\x00-\x1f])/     ) { '\\%02x' % $1[0].ord }     \
               .gsub(/([\\+\"<>;,\#=])/  ) { '\\' + $1            }
        end
    end

    refine Net::LDAP::Entry do
        using LOM::LDAP::Converters
        
        def _cast(val, cnv=nil, &block)
            if cnv && block
                raise ArgumentError,
                      'converter can\'t be pass as parameter and as block'
            elsif block
                cnv = block
            end
            
            case cnv
            when Method, Proc then cnv.call(val)
            when Class        then cnv.from_ldap(val)
            when nil          then val
            else raise ArgumentError, "unhandled converter type (#{cnv.class})"
            end
        end
        private :_cast

        def [](name, cnv=nil, &block)
            values = super(name)
            if cnv.nil? && block.nil?
            then values
            else values.map {|e| _cast(e, cnv, &block) }
            end
        end
        alias :all :[]
        
        def first(name, cnv=nil, &block)
            if value = super(name)
                _cast(value, cnv, &block)
            end
        end
    end
end

end
