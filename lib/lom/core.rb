require_relative 'version'

class LOM
    # Standard Error
    class Error < StandardError
    end

    # Entry not found
    class EntryNotFound < Error
    end

    # Mapping error
    class MappingError < Error
    end

    # Conversion error
    class ConvertionError < Error
    end

    
    # Time format used in ldap
    TIME_FORMAT = "%Y%m%d%H%M%SZ"

    
    # Convert a Date/Time object to an ldap string representation
    #
    # @param [Date, Time] ts
    #
    # @return [String] string representation of time in ldap 
    #
    def self.to_ldap_time(ts)
        case ts
        when Date, Time then ts.strftime(TIME_FORMAT)
        when nil        then nil
        else raise ArgumentError
        end
    end

    # Get debugging mode
    def self.debug
        @@debug ||= []
    end

    # Set debugging mode
    def self.debug=(v)
        @@debug = v
    end
end
