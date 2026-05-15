namespace ArchrealmsPassport.Core.Protocol;

public static class PassportAiProtocolDefaults
{
    public const string LocalGatewayUrl = "https://ai.archrealms.local";
    public const string ApprovedKnowledgePackId = "archrealms-mvp-approved-knowledge";
    public const string GatewayAudience = "archrealms-ai-gateway";
    public const string ChallengeEndpoint = "/ai/challenge";
    public const string ChatEndpoint = "/ai/chat";
    public const string SessionEndpoint = "/ai/session";
    public const string QuotaEndpoint = "/ai/quota";
    public const string FeedbackEndpoint = "/ai/feedback";
    public const string StatusEndpoint = "/ai/status";
}
