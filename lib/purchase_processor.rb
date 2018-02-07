module Unimatrix
  module PurchaseProcessor
    GEM_ROOT = File.expand_path( '../..', __FILE__ )
  end
end

require './adapter/free/free_adapter'
require './adapter/paypal/paypal_adapter'
require './adapter/stripe/stripe_adapter'
