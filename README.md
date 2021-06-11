LDAP Object Mapper
==================

Allow to map LDAP object to ruby object.

It is best used with dry-struct and dry-struct-setters libraries


Examples
========

~~~ruby
require 'net/ldap'
require 'lom/ldap'

using LOM::LDAP::Extensions

# Define LDAP handler used by LOM
LH = Net::LDAP.connect('ldap://127.0.0.1')
LH.auth 'uid=root,ou=Admins,dc=example,dc=com', 'foobar'
~~~

~~~ruby
# Defining mapping between LDAP and ruby using Dry::Struct
#
class User < Dry::Struct
    include Dry::Struct::Setters
    using LOM::LDAP::Extensions
    
    ADMINS_BRANCH     = 'ou=Admins,dc=example,dc=com'
    TEAMS_BRANCH      = 'ou=Team,dc=example,dc=com'
    
    #
    # Defining LDAP mapping
    # 
    extend LOM::Mapper

    ldap_branch  "ou=People,dc=example,dc=com"
    ldap_filter  '(objectClass=inetOrgPerson)'
    ldap_attrs   '*', '+'
    ldap_prefix  :uid
    
    ldap_from   do
        {
            :firstname       => first(:givenName,             String   ),
            :lastname        => first(:sn,                    String   ),
            :email           => first(:mail,                  String   ),
            :homepage        => first(:labeledURI,            String   ),
            :address         => first(:postalAddress,         String   ),
            :title           => first(:title,                 String   ),
            :type            =>   all(:objectClass,           String   )
                                    .map(&:downcase)
                                    .include?('posixaccount') ? :full : :minimal,
            :login           => first(:uid,                   String   ),
            :password        => nil,
            :managers        =>   all(:manager,               String   )
                                    .map {|m| User.ldap_dn_to_id(m) },
            :locked          => first(:pwdAccountLockedTime,  Time     ),
            :uid             => first(:uidNumber,             Integer  ),
            :gid             => first(:gidNumber,             Integer  ),
            :home            => first(:homeDirectory,         String   ),
            :teams           =>   all(:memberOf,              String   ).map{|m|
                    LOM.id_from_dn(m, TEAMS_BRANCH, :cn)
                }.compact,
        }.compact
    end

    ldap_to do
        oclass = [ 'inetOrgPerson' ]
        if type == :full
            oclass += [ 'posixAccount', 'sambaSamAccount', 'pwdPolicy' ]
            { :gecos      => fullname,
              :loginShell => '/bin/bash'
            }
        end
        
        { :givenName        => firstname,
          :sn               => lastname,
          :cn               => fullname,
          :mail             => email,
          :labeledURI       => homepage,
          :postalAddress    => address,
          :title            => title,
          :uid              => login,
          :manager          => managers.map {|m| User.ldap_dn_from_id(m) },
          :pwdAccountLockedTime => locked,
          :uidNumber        => uid,
          :gidNumber        => gid,
          :homeDirectory    => home.to_s,
        }
    end

    ldap_list    :locked,  ->(predicate=true) do
        Filtered.exists(:pwdAccountLockedTime, predicate: predicate)
    end

    ldap_list   :manager,  ->(manager) do
        Filtered.has(:manager, manager) {|m|
            case m
            when true,  nil   then Filtered::ANY
            when false, :none then Filtered::NONE
            else User.ldap_dn_from_id(m.to_str)
            end
        }
    end
    
    ldap_list    :query,    ->(str) do
        Filtered.match(:uid, str) |
        Filtered.match(:cn,  str) |
        Filtered.match(:givenName, str) | Filtered.match(:sn, str)
    end
    

    #
    # Object structure
    #
    
    transform_keys(&:to_sym)
    
    attribute  :firstname,       Types::String
    attribute  :lastname,        Types::String
    attribute  :email,           Types::EMail
    attribute? :homepage,        Types::WebPage.optional
    attribute? :address,         Types::String.optional
    attribute  :title,           Types::String
    attribute  :type,            Types::Symbol.enum(:minimal, :full)
    attribute  :login,           Types::Login
    attribute? :password,        Types::Password.optional
    attribute? :managers,        Types::Array.of(Types::Login)
    attribute? :locked,          Types::Time.optional
    attribute? :uid,             Types::Integer
    attribute? :gid,             Types::Integer
    attribute? :home,            Types::Pathname
    attribute  :teams,           Types::Array.of(Types::Team)

    # Various User representation that can be used in processing
    # as string, in sql statement, as JSON
    def to_s            ; self.login                       ; end
    def to_str          ; self.login                       ; end
    def sql_literal(ds) ; ds.literal(self.login)           ; end
    def to_json(*a)     ; self.to_hash.compact.to_json(*a) ; end
   
    # User full name.
    def fullname
        [ firstname, lastname ].join(' ')
    end
end
~~~


~~~ruby
# Return user id of users for which account has been locked and 
# with "John Doe" as manager 
User.locked(true).manager('jdoe').list

# Return list of users (as User instance)  without managers
User.manager(false).all
~~~
