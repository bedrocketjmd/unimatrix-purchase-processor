module Localizer
  def retrieve_app_product( resource )
    method_call = resource.respond_to?( :customer_product ) ? :customer_product : :realm_product
    resource.send( method_call )
  end
end
