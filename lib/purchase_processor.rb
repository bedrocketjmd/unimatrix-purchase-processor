require 'purchase_processor/configuration'
require 'purchase_processor/adapter/adapter'

# FreeAdapter Files
require 'purchase_processor/adapter/free/free_adapter'

# Paypal Files
require 'purchase_processor/adapter/paypal/paypal_adapter'

# Stripe Files
require 'purchase_processor/adapter/stripe/stripe_adapter'
require 'purchase_processor/adapter/stripe/stripe_attribute'
require 'purchase_processor/adapter/stripe/stripe_charge'
require 'purchase_processor/adapter/stripe/stripe_customer'
require 'purchase_processor/adapter/stripe/stripe_refund'
require 'purchase_processor/adapter/stripe/stripe_subscription'
