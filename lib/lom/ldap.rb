require_relative 'ldap/converters'
require_relative 'ldap/extensions'

class LOM
    using LDAP::Extensions

    # Retrieve the identifier.
    #
    # The given `dn` should be a direct child of the `branch`,
    # and if `attr` is specified, the attribute name should also match.
    #
    # ~~~
    # dn = "uid=jdoe,ou=People,dc=example,dc=com"
    # LOM.id_from_dn(dn, "ou=People,dc=example,dc=com", :uid)
    # ~~~
    #
    # @param [String]        dn      DN of the object 
    # @param [String]        branch  Branch the DN should belong
    # @param [Symbol,String] attr    Attribute name
    #
    # @return [String] Identifier
    # @return [nil]    Unable to extract identifier
    #
    def self.id_from_dn(dn, branch, attr = nil)
        if sub = Net::LDAP::DN.sub?(dn, branch)
            k, v, o = sub.to_a
            if o.nil? && (!attr.nil? || (k == attr.to_s))
                v
            end
        end
    end

end
