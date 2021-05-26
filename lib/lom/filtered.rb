require 'date'
require_relative 'ldap/converters'
require_relative 'ldap/extensions'

class LOM

class Filtered
    include Enumerable

    using LDAP::Extensions
    using LDAP::Converters

    NONE = Object.new.freeze
    ANY  = Object.new.freeze

    def initialize(src, filter = nil, paged: nil)
        @src      = src
        @filter   = filter
        @paged    = paged
    end
    attr_reader :src, :filter, :paged

    def |(o)
        _operator_2('|', o)
    end

    def &(o)
        _operator_2('&', o)
    end

    def ~@
        _operator_1('!')
    end

    def respond_to_missing?(method_name, include_private = false)
        @src.ldap_listing.include?(method_name) || super
    end
    
    def method_missing(method_name, *args, &block)
        if @src.ldap_listing.include?(method_name)
            self & @src.send(method_name, *args, &block)
        else
            super
        end        
    end

    def paginate(page, page_size)
        @paged = [ page, page_size ]
    end
    
    def each(*args, &block)
        @src.each(*args, filter: @filter, paged: self.paged, &block)
    end

    def all
        each(:object).to_a
    end

    def list
        each(:id).to_a
    end


    def self.escape(val)
        val = if    val.respond_to?(:to_ldap) then val.to_ldap
              elsif val.respond_to?(:to_str ) then val.to_str
              elsif val.kind_of?(Symbol)      then val.to_s
              else raise ArgumentError, 'can\'t convert to string'
              end
        Net::LDAP::Filter.escape(val)
    end

    # Test if an attribute exists
    def self.exists(attr, predicate: true)
        case predicate
        when true,  nil   then   "(#{attr}=*)"
        when false, :none then "(!(#{attr}=*))"
        else raise ArgumentError
        end
    end

    # Test if an attribute is of the specified value
    def self.is(attr, val, predicate: true)
        case predicate
        when true,  nil then   "(#{attr}=#{escape(val)})"
        when false      then "(!(#{attr}=#{escape(val)}))"
        else raise ArgumentError
        end
    end

    # Test if an attribute has the specified value.
    # Using NONE will test for absence, ANY for existence
    def self.has(attr, val)
        val = yield(val) if block_given?

        case val
        when ANY  then   "(#{attr}=*)"
        when NONE then "(!(#{attr}=*))"
        else             "(#{attr}=#{escape(val)})"
        end
    end

    # Test if an attribute as a time before the specified timestamp
    # If an integer is given it is added to the today date
    def self.before(attr, ts, predicate: true)
        ts = Date.today + ts if ts.kind_of?(Integer)
        ts = LOM.to_ldap_time(ts)       
        "(#{attr}<=#{ts})".then {|f| predicate ? f : "(!#{f})" }
    end

    # Test if an attribute as a time after the specified timestamp
    # If an integer is given it is subtracted to the today date
    def self.after(attr, ts, predicate: true)
        ts = Date.today - ts if ts.kind_of?(Integer)
        ts = LOM.to_ldap_time(ts)
        "(#{attr}>=#{ts})".then {|f| predicate ? f : "(!#{f})" }
    end

    private
    
    def _operator_2(op, o)
        if @src != o.src
            raise ArgumentError, 'filter defined with different sources'
        end
        _filter = if !@filter.nil? && !o.filter.nil?
                  then Net::LDAP.filter(op, @filter, o.filter)
                  else @filter || o.filter
                  end
        Filtered.new(@src, _filter, paged: o.paged || self.paged)
    end

    def _operator_1(op)
        Filtered.new(@src, Net::LDAP.filter(op, @filter),
                     paged: self.paged)
    end
    
end
end
