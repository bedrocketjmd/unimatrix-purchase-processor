class OrchestratorError < OrchestratorResponse
  def initialize( error_class, message )
    super( false, nil, nil, error_class, message )
  end
end
