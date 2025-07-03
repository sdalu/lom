require 'date'
require 'set'

require_relative '../core'


module LOM::LDAP
module Converters

    #
    # Integer
    #

    refine Integer do
        def to_ldap
            self.to_s
        end
    end

    refine Integer.singleton_class do
        def from_ldap(v)
            Integer(v)
        end
    end



    #
    # String
    #

    refine String do
        def to_ldap
            self
        end
    end

    refine String.singleton_class do
        def from_ldap(v)
            v
        end
    end



    #
    # Date / Time
    #

    refine Date do
        def to_ldap
            self.strftime("%Y%m%d%H%M%SZ")
        end
    end

    refine Date.singleton_class do
        def from_ldap(date)
            return nil if date.nil?
            Date.parse(date)
        end
    end

    refine Time do
        def to_ldap
            self.gmtime.strftime("%Y%m%d%H%M%SZ")
        end
    end

    refine Time.singleton_class do
        def from_ldap(time)
            return nil if time.nil?
            self::gm(time[0,4].to_i, time[4,2].to_i,  time[6,2].to_i,
                     time[8,2].to_i, time[10,2].to_i, time[12,2].to_i)
        end
    end



    #
    # Boolean
    #

    refine TrueClass do
        def to_ldap
            'TRUE'
        end
    end

    refine TrueClass.singleton_class do
        def from_ldap(v)
            v == 'TRUE'
        end
    end

    refine FalseClass do
        def to_ldap
            'FALSE'
        end
    end



    #
    # Array / Set
    #

    refine Set do
        def to_ldap
            self.to_a.to_ldap
        end
    end

    refine Array do
        def to_ldap
            self.map { |val|
                if    val.respond_to?(:to_ldap) then val.to_ldap
                elsif val.respond_to?(:to_str ) then val.to_str
                elsif val.kind_of?(Symbol)      then val.to_s
                else raise LOM::ConvertionError,
                           "can't convert to string (#{val.class})"
                end
            }.tap {|list|
                if err = list.find {|e| ! e.kind_of?(String) }
                    raise LOM::ConvertionError,
                          "detected a non-string element (#{err.class})"
                end
            }
        end
    end

end
end
