require_relative 'ldap/converters'
require_relative 'ldap/extensions'

class LOM
    using LDAP::Extensions

    def self.id_from_branch(dn, branch, prefix = nil)
        if sub = Net::LDAP::DN.sub?(dn, branch)
            k, v, o = sub.to_a
            if o.nil? && (!prefix.nil? || (k == prefix.to_s))
                v
            end
        end
    end

end
