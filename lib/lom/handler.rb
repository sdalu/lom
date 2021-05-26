require 'forwardable'

class LOM
    using LDAP::Extensions

    
    def self.lh=(lh)
        @lh = lh
    end

    def self.lh
        @lh || const_get(:LH) || $lh
    end   


    # extend Forwardable
    #
    # def self.connect(*args)
    #     self.new(Net::LDAP.connect(*args))
    # end
    #
    # def initialize(lh)
    #     @lh = lh
    # end
    #
    # def_delegator :@lh, :search
    # def_delegator :@lh, :update
    # def_delegator :@lh, :modify
    # def_delegator :@lh, :add
    # def_delegator :@lh, :delete

end
                 


