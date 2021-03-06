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

    class NoSource < Error
    end

    def initialize(filter = nil, src: nil, paged: nil)
        if filter.is_a?(Filtered)
            @filter   = filter.filter
            @src      = src || filter.src
            @paged    = paged || filter.paged
        else
            @filter   = filter
            @src      = src
            @paged    = paged
        end
    end
    attr_reader :src, :filter, :paged

    # Join two filter using a or operation
    def |(o)
        _operator_2('|', o)
    end

    # Join two filter using a and operation
    def &(o)
        _operator_2('&', o)
    end

    # Take the negation of this filter
    def ~@
        _operator_1('!')
    end


    # Ask for paginated data.
    #
    # @note That is not supported by net/ldap and is emulated by taking
    #       a slice of the retrieved data. Avoid using.
    #
    # @param [Integer] page index (starting from 1)
    # @param [Integer] page size
    #
    # @return [self]
    def paginate(page, page_size)
        @paged = [ page, page_size ]
        self
    end

    # Iterate over matching data
    def each(*args, rawfilter: nil, &block)
        raise NoSource if @src.nil?
        @src.each(*args, filter: @filter, rawfilter: rawfilter,
                  paged: self.paged, &block)
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

    # Escape (and convert) a value for correct processing.
    #
    # Before escaping, the value will be converted to string using
    # if possible #to_ldap, #to_str, and #to_s in case of symbol
    #
    # @param [Object] val value to be escaped
    #
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
        self.new(case predicate
                 when true,  nil   then   "(#{attr}=*)"
                 when false, :none then "(!(#{attr}=*))"
                 else raise ArgumentError
                 end)
    end

    # Test if an attribute is of the specified value
    def self.is(attr, val, predicate: true)
        self.new(case predicate
                 when true,  nil then   "(#{attr}=#{escape(val)})"
                 when false      then "(!(#{attr}=#{escape(val)}))"
                 else raise ArgumentError
                 end)
    end

    # Test if an attribute has the specified value.
    # Using NONE will test for absence, ANY for existence
    def self.has(attr, val)
        val = yield(val) if block_given?

        self.new(case val
                 when ANY  then   "(#{attr}=*)"
                 when NONE then "(!(#{attr}=*))"
                 else             "(#{attr}=#{escape(val)})"
                 end)
    end

    # Test if an attribute match the specified value
    def self.match(attr, val, predicate: true)
        self.new(case predicate
                 when true,  nil then   "(#{attr}=*#{escape(val)}*)"
                 when false      then "(!(#{attr}=*#{escape(val)}*))"
                 else raise ArgumentError
                 end)
    end

    # Test if an attribute as a time before the specified timestamp
    # If an integer is given it is added to the today date
    def self.before(attr, ts, predicate: true)
        ts = Date.today + ts if ts.kind_of?(Integer)
        ts = LOM.to_ldap_time(ts)       
        self.new("(#{attr}<=#{ts})".then {|f| predicate ? f : "(!#{f})" })
    end

    # Test if an attribute as a time after the specified timestamp
    # If an integer is given it is subtracted to the today date
    def self.after(attr, ts, predicate: true)
        ts = Date.today - ts if ts.kind_of?(Integer)
        ts = LOM.to_ldap_time(ts)
        self.new("(#{attr}>=#{ts})".then {|f| predicate ? f : "(!#{f})" })
    end

    private

    # Operation with 2 elements
    def _operator_2(op, o)
        if !@src.nil? && !o.src.nil? && @src != o.src
            raise ArgumentError, 'filter defined with different sources'
        end
        _filter = if !@filter.nil? && !o.filter.nil?
                  then Net::LDAP.filter(op, @filter, o.filter)
                  else @filter || o.filter
                  end
        Filtered.new(_filter, src: @src || o.src, paged: o.paged || self.paged)
    end

    # Operation with 1 element
    def _operator_1(op)
        Filtered.new(Net::LDAP.filter(op, @filter), src: @src,
                     paged: self.paged)
    end

    # Check if an ldap_list has been defined with that name
    def respond_to_missing?(method_name, include_private = false)
        return super if @src.nil?
        @src.ldap_listing.include?(method_name) || super
    end
    
    # Call the ldap_list defined with that name
    def method_missing(method_name, *args, &block)
        if @src&.ldap_listing.include?(method_name)
        then self & @src.send(method_name, *args, &block)
        else super
        end        
    end
    
end
end
