class OrchestratorRedirect < OrchestratorResponse
  def initialize( transaction, redirect_url )
    super( true, transaction, redirect_url )
  end
end
