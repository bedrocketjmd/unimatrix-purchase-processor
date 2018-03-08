class OrchestratorSuccess < OrchestratorResponse
  def initialize( transaction )
    super( true, transaction )
  end
end
