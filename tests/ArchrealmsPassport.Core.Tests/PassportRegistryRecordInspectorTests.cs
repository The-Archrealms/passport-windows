using System.Text;
using ArchrealmsPassport.Core.Protocol;
using Xunit;

namespace ArchrealmsPassport.Core.Tests;

public sealed class PassportRegistryRecordInspectorTests
{
    [Fact]
    public void InspectsRegistryRecordSummaryFields()
    {
        var json = """
        {
          "schema_version": 1,
          "record_type": "passport_test_record",
          "event_id": "event-1",
          "created_utc": "2026-05-15T00:00:00Z",
          "signature_status": "wallet_signed",
          "content_ref": {
            "cid": "bafytest"
          },
          "signature": {
            "signed_payload_path": "records/payload.json",
            "signed_payload_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "signature_path": "records/signature.json"
          },
          "wallet_signature": {
            "wallet_public_key_path": "records/wallet/pub.der",
            "signed_payload_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          }
        }
        """;

        var inspection = PassportRegistryRecordInspector.Inspect(Encoding.UTF8.GetBytes(json), "records/event.json");

        Assert.True(inspection.IsRecord);
        Assert.True(inspection.IsEnvelopeValid);
        Assert.Equal("1", inspection.SchemaVersion);
        Assert.Equal("passport_test_record", inspection.RecordType);
        Assert.Equal("event-1", inspection.RecordId);
        Assert.Equal("wallet_signed", inspection.Status);
        Assert.Equal("bafytest", inspection.Cid);
        Assert.Equal("records/payload.json", inspection.SignedPayloadPath);
        Assert.Equal("records/wallet/pub.der", inspection.WalletPublicKeyPath);
        Assert.True(PassportRegistryRecordInspector.MatchesFilter(inspection, "wallet"));
        Assert.True(PassportRegistryRecordInspector.MatchesFilter(inspection, "bafy"));
    }

    [Fact]
    public void RejectsJsonWithoutRecordType()
    {
        var inspection = PassportRegistryRecordInspector.Inspect(Encoding.UTF8.GetBytes("{\"schema_version\":1,\"event_id\":\"event-1\"}"));

        Assert.False(inspection.IsRecord);
        Assert.Contains("record_type_required", inspection.ValidationFailures);
        Assert.False(PassportRegistryRecordInspector.MatchesFilter(inspection, "event-1"));
    }

    [Fact]
    public void ReportsCommonEnvelopeValidationFailures()
    {
        var inspection = PassportRegistryRecordInspector.Inspect(Encoding.UTF8.GetBytes("{\"schema_version\":1,\"record_type\":\"passport_identity_record\"}"));

        Assert.True(inspection.IsRecord);
        Assert.False(inspection.IsEnvelopeValid);
        Assert.Contains("record_identifier_required", inspection.ValidationFailures);
        Assert.Contains("created_utc_required", inspection.ValidationFailures);
        Assert.True(PassportRegistryRecordInspector.MatchesFilter(inspection, "created_utc_required"));
    }

    [Fact]
    public void ReportsKnownRecordFamilyMissingFields()
    {
        var json = """
        {
          "schema_version": 1,
          "record_type": "passport_identity_record",
          "record_id": "identity-1",
          "created_utc": "2026-05-15T00:00:00Z",
          "effective_utc": "2026-05-15T00:00:00Z",
          "status": "active",
          "archrealms_identity_id": "archrealms:citizen:dan",
          "identity_mode": "citizen",
          "citizenship_class": "citizen",
          "declared_scope": "mvp",
          "recovery_authority": {},
          "attestation_refs": [],
          "summary": "Identity record."
        }
        """;

        var inspection = PassportRegistryRecordInspector.Inspect(Encoding.UTF8.GetBytes(json));

        Assert.True(inspection.IsRecord);
        Assert.False(inspection.IsEnvelopeValid);
        Assert.Contains("record_family_required_field_missing:display_name", inspection.ValidationFailures);
    }

    [Fact]
    public void AllowsTemplatePlaceholderDatesWhenRequested()
    {
        var json = """
        {
          "schema_version": 1,
          "record_type": "passport_test_record",
          "record_id": "<record-id>",
          "created_utc": "<YYYY-MM-DDTHH:MM:SSZ>"
        }
        """;

        var strictInspection = PassportRegistryRecordInspector.Inspect(Encoding.UTF8.GetBytes(json));
        var templateInspection = PassportRegistryRecordInspector.Inspect(
            Encoding.UTF8.GetBytes(json),
            "passport-test.template.json",
            allowTemplatePlaceholders: true);

        Assert.Contains("created_utc_invalid", strictInspection.ValidationFailures);
        Assert.True(templateInspection.IsEnvelopeValid);
    }

    [Fact]
    public void ReportsWalletBindingPolicyFailures()
    {
        var json = """
        {
          "schema_version": 1,
          "record_type": "passport_wallet_key_binding",
          "record_id": "binding-1",
          "created_utc": "2026-05-15T00:00:00Z",
          "release_lane": "staging",
          "ledger_namespace": "staging-ledger",
          "policy_version": "passport-mvp-v1",
          "status": "active",
          "archrealms_identity_id": "identity-1",
          "authorizing_device_id": "device-1",
          "wallet_key_id": "wallet-1",
          "wallet_key_algorithm": "RSA",
          "wallet_key_size_bits": 3072,
          "wallet_public_key_path": "records/passport/wallet/public-keys/wallet-1.spki.der",
          "wallet_public_key_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "authorized_scopes": [
            "sign_arch_operations",
            "sign_cc_operations",
            "sign_conversion_quotes",
            "sign_escrow_redemption",
            "alter_identity"
          ],
          "prohibited_scopes": [
            "alter_identity",
            "alter_citizenship",
            "alter_office",
            "alter_registry_authority",
            "alter_constitutional_status",
            "alter_crown_authority"
          ],
          "summary": "Wallet binding."
        }
        """;

        var inspection = PassportRegistryRecordInspector.Inspect(Encoding.UTF8.GetBytes(json));

        Assert.True(inspection.IsRecord);
        Assert.False(inspection.IsEnvelopeValid);
        Assert.Contains(
            "wallet_key_binding_policy:authorized_scope_forbidden:alter_identity",
            inspection.ValidationFailures);
    }

    [Theory]
    [InlineData("record_id")]
    [InlineData("event_id")]
    [InlineData("quote_id")]
    [InlineData("execution_id")]
    [InlineData("correction_id")]
    public void ReadsSupportedRecordIdentifierFields(string identifierField)
    {
        var json = $$"""
        {
          "schema_version": 1,
          "record_type": "passport_test_record",
          "{{identifierField}}": "record-123",
          "created_utc": "2026-05-15T00:00:00Z"
        }
        """;

        var inspection = PassportRegistryRecordInspector.Inspect(Encoding.UTF8.GetBytes(json));

        Assert.True(inspection.IsEnvelopeValid);
        Assert.Equal("record-123", inspection.RecordId);
    }

    [Fact]
    public void ReadsSourceRootCid()
    {
        var json = """
        {
          "schema_version": 1,
          "record_type": "passport_test_record",
          "record_id": "record-123",
          "created_utc": "2026-05-15T00:00:00Z",
          "source": {
            "root_cid": "bafyroot"
          }
        }
        """;

        var inspection = PassportRegistryRecordInspector.Inspect(Encoding.UTF8.GetBytes(json));

        Assert.True(inspection.IsEnvelopeValid);
        Assert.Equal("bafyroot", inspection.Cid);
    }

    [Fact]
    public void ReportsInvalidJson()
    {
        var inspection = PassportRegistryRecordInspector.Inspect(Encoding.UTF8.GetBytes("{"));

        Assert.False(inspection.IsRecord);
        Assert.Contains("invalid_json", inspection.ValidationFailures);
        Assert.False(string.IsNullOrWhiteSpace(inspection.Sha256));
    }

    [Fact]
    public void InspectsUtf8BomEncodedRecords()
    {
        var json = """
        {
          "schema_version": 1,
          "record_type": "passport_test_record",
          "record_id": "record-123",
          "created_utc": "2026-05-15T00:00:00Z"
        }
        """;
        var preamble = Encoding.UTF8.GetPreamble();
        var payload = Encoding.UTF8.GetBytes(json);
        var bytes = preamble.Concat(payload).ToArray();

        var inspection = PassportRegistryRecordInspector.Inspect(bytes);

        Assert.True(inspection.IsEnvelopeValid);
        Assert.Equal("passport_test_record", inspection.RecordType);
    }
}
