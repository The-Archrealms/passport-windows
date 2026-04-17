using System;
using System.IO;
using System.Text.Json;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportSettingsStore
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        public string SettingsPath
        {
            get
            {
                return PassportEnvironment.GetSettingsPath();
            }
        }

        public PassportSettings Load()
        {
            if (!File.Exists(SettingsPath))
            {
                return new PassportSettings();
            }

            var json = File.ReadAllText(SettingsPath);
            return JsonSerializer.Deserialize<PassportSettings>(json, JsonOptions) ?? new PassportSettings();
        }

        public void Save(PassportSettings settings)
        {
            var json = JsonSerializer.Serialize(settings, JsonOptions);
            File.WriteAllText(SettingsPath, json);
        }
    }
}
