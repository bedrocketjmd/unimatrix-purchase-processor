require 'adapter/free/free_adapter'
require 'adapter/paypal/paypal_adapter'
require 'adapter/stripe/stripe_adapter'
require 'adapter/localizer'

module Unimatrix
  class PurchaseProcessor
    GEM_ROOT = File.expand_path( '../..', __FILE__ )
  end
end
