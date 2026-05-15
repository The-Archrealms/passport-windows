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
          "record_type": "passport_monetary_ledger_event",
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
        Assert.Equal("passport_monetary_ledger_event", inspection.RecordType);
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
