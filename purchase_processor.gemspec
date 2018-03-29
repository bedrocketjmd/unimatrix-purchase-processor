# coding: utf-8
lib     = File.expand_path( '../lib',  __FILE__ )

$LOAD_PATH.unshift( lib )     unless $LOAD_PATH.include?( lib )

Gem::Specification.new do | spec |
  spec.name          = 'purchase_processor'
  spec.version       = '1.2.0'
  spec.authors       = [ 'Stefan Hartmann' ]
  spec.email         = [ 'stefanhartmann@sportsrocket.com' ]
  spec.summary       = %q{ Library of Stripe + Paypal related purchase processing methods. }
  spec.homepage      = 'https://github.com/bedrocketjmd/unimatrix-purchase-processor'
  spec.license       = 'MIT'
  spec.files         = [ *Dir.glob( 'lib/**/**/*'), *Dir.glob( 'config/**/*' ) ]
  spec.require_paths = [ 'lib' ]

  spec.add_development_dependency 'codeclimate-test-reporter', '~> 0'
  spec.add_development_dependency 'dotenv', '~> 2.1.1', '>= 2.1.1'
  spec.add_development_dependency 'bundler', '~> 1.11'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'pry', '~> 0'
  spec.add_development_dependency 'pry-nav', '~> 0'
  spec.add_runtime_dependency 'stripe', '>= 0'
  spec.add_runtime_dependency 'paypal-sdk-rest', '>= 0'
  spec.add_runtime_dependency 'avatax', '>= 0'
  spec.add_runtime_dependency 'money', '>= 0'
  spec.add_runtime_dependency 'money-open-exchange-rates', '~> 1.0.2'
end
