# -*- encoding: utf-8 -*-

require_relative 'lib/lom/version'

Gem::Specification.new do |s|
    s.name        = 'lom'
    s.version     = LOM::VERSION
    s.summary     = "LDAP Object Mapper"
    s.description =  <<~EOF
      
      Ease processing of parameters in Sinatra framework.
      Integrates well with dry-types, sequel, ...

      Example:
        want! :user,    Dry::Types::String, User
        want? :expired, Dry::Types::Params::Bool.default(true)
      EOF

    s.homepage    = 'https://gitlab.com/sdalu/lom'
    s.license     = 'MIT'

    s.authors     = [ "Stéphane D'Alu" ]
    s.email       = [ 'stephane.dalu@insa-lyon.fr' ]

    s.files       = %w[ README.md lom.gemspec ] +
                    Dir['lib/**/*.rb']

    s.add_dependency 'net-ldap'
    s.add_development_dependency 'yard', '~>0'
    s.add_development_dependency 'rake', '~>13'
end
