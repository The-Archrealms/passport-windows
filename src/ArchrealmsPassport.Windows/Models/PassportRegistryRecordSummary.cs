using System;
using System.Collections.Generic;

namespace ArchrealmsPassport.Windows.Models
{
    public sealed class PassportRegistryRecordSummary
    {
        public string SchemaVersion { get; set; } = string.Empty;

        public string RecordType { get; set; } = string.Empty;

        public string RecordId { get; set; } = string.Empty;

        public string CreatedUtc { get; set; } = string.Empty;

        public string Status { get; set; } = string.Empty;

        public string RelativePath { get; set; } = string.Empty;

        public string Sha256 { get; set; } = string.Empty;

        public string Cid { get; set; } = string.Empty;

        public string SignedPayloadPath { get; set; } = string.Empty;

        public string SignedPayloadSha256 { get; set; } = string.Empty;

        public string SignaturePath { get; set; } = string.Empty;

        public string WalletPublicKeyPath { get; set; } = string.Empty;

        public string WalletSignedPayloadSha256 { get; set; } = string.Empty;

        public IReadOnlyList<string> ValidationFailures { get; set; } = Array.Empty<string>();
    }
}
