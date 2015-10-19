﻿// ----------------------------------------------------------------------------------
//
// Copyright Microsoft Corporation
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// ----------------------------------------------------------------------------------

using System;
using System.Collections.Generic;
using System.Management.Automation;
using Microsoft.Azure.Commands.Compute.Common;
using Microsoft.Azure.Commands.Compute.Models;
using Microsoft.WindowsAzure.Commands.Utilities.Common;
using Microsoft.Azure.Management.Compute.Models;

namespace Microsoft.Azure.Commands.Compute
{
    [Cmdlet(
        VerbsCommon.Set,
        ProfileNouns.OSDisk,
        DefaultParameterSetName = DefaultParamSet),
    OutputType(
        typeof(PSVirtualMachine))]
    public class SetAzureVMOSDiskCommand : Microsoft.Azure.Commands.ResourceManager.Common.AzureRMCmdlet
    {
        protected const string DefaultParamSet = "DefaultParamSet";
        protected const string WindowsParamSet = "WindowsParamSet";
        protected const string LinuxParamSet = "LinuxParamSet";
        protected const string WindowsDiskEncryptionParameterSet = "WindowsDiskEncryptionParameterSet";
        protected const string LinuxDiskEncryptionParameterSet = "LinuxDiskEncryptionParameterSet";

        [Alias("VMProfile")]
        [Parameter(
            Mandatory = true,
            Position = 0,
            ValueFromPipeline = true,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMProfile)]
        [ValidateNotNullOrEmpty]
        public PSVirtualMachine VM { get; set; }

        [Alias("OSDiskName", "DiskName")]
        [Parameter(
            Mandatory = true,
            Position = 1,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskName)]
        [ValidateNotNullOrEmpty]
        public string Name { get; set; }

        [Alias("OSDiskVhdUri", "DiskVhdUri")]
        [Parameter(
            Position = 2,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskVhdUri)]
        [ValidateNotNullOrEmpty]
        public string VhdUri { get; set; }

        [Parameter(
            Position = 3,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskCaching)]
        [ValidateNotNullOrEmpty]
        [ValidateSet(ValidateSetValues.ReadOnly, ValidateSetValues.ReadWrite, ValidateSetValues.None)]
        public string Caching { get; set; }

        [Alias("SourceImage")]
        [Parameter(
            Position = 4,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMSourceImageUri)]
        [ValidateNotNullOrEmpty]
        public string SourceImageUri { get; set; }

        [Parameter(
            Mandatory = true,
            Position = 5,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMDataDiskCreateOption)]
        [ValidateNotNullOrEmpty]
        [ValidateSet(DiskCreateOptionTypes.Empty, DiskCreateOptionTypes.Attach, DiskCreateOptionTypes.FromImage)]
        public string CreateOption { get; set; }

        [Parameter(
            ParameterSetName = WindowsParamSet,
            Position = 6,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskWindowsOSType)]
        [Parameter(
            ParameterSetName = WindowsDiskEncryptionParameterSet,
            Position = 6,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskWindowsOSType)]
        public SwitchParameter Windows { get; set; }

        [Parameter(
            ParameterSetName = LinuxParamSet,
            Position = 6,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskLinuxOSType)]
        [Parameter(
            ParameterSetName = LinuxDiskEncryptionParameterSet,
            Position = 6,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskLinuxOSType)]
        public SwitchParameter Linux { get; set; }

        [Parameter(
            ParameterSetName = WindowsDiskEncryptionParameterSet,
            Mandatory = true,
            Position = 7,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskLinuxOSType)]
        [Parameter(
            ParameterSetName = LinuxDiskEncryptionParameterSet,
            Mandatory = true,
            Position = 7,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskLinuxOSType)]
        public Uri DiskEncryptionKeyUrl { get; set; }

        [Parameter(
            ParameterSetName = WindowsDiskEncryptionParameterSet,
            Mandatory = true,
            Position = 8,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskLinuxOSType)]
        [Parameter(
            ParameterSetName = LinuxDiskEncryptionParameterSet,
            Mandatory = true,
            Position = 8,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskLinuxOSType)]
        public string DiskEncryptionKeyVaultId { get; set; }

        [Parameter(
            ParameterSetName = WindowsDiskEncryptionParameterSet,
            Mandatory = false,
            Position = 9,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskLinuxOSType)]
        [Parameter(
            ParameterSetName = LinuxDiskEncryptionParameterSet,
            Mandatory = false,
            Position = 9,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskLinuxOSType)]
        public Uri KeyEncryptionKeyUrl { get; set; }

        [Parameter(
            ParameterSetName = WindowsDiskEncryptionParameterSet,
            Mandatory = false,
            Position = 10,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskLinuxOSType)]
        [Parameter(
            ParameterSetName = LinuxDiskEncryptionParameterSet,
            Mandatory = false,
            Position = 10,
            ValueFromPipelineByPropertyName = true,
            HelpMessage = HelpMessages.VMOSDiskLinuxOSType)]
        public string KeyEncryptionKeyVaultId { get; set; }

        protected override void ProcessRecord()
        {
            if (this.VM.StorageProfile == null)
            {
                this.VM.StorageProfile = new StorageProfile();
            }

            this.VM.StorageProfile.OSDisk = new OSDisk
            {
                Caching = this.Caching,
                Name = this.Name,
                OperatingSystemType = this.Windows.IsPresent ? OperatingSystemTypes.Windows : this.Linux.IsPresent ? OperatingSystemTypes.Linux : null,
                VirtualHardDisk = string.IsNullOrEmpty(this.VhdUri) ? null : new VirtualHardDisk
                {
                    Uri = this.VhdUri
                },
                SourceImage = string.IsNullOrEmpty(this.SourceImageUri) ? null : new VirtualHardDisk
                {
                    Uri = this.SourceImageUri
                },
                CreateOption = this.CreateOption,
                EncryptionSettings =
                (this.ParameterSetName.Equals(WindowsDiskEncryptionParameterSet) || this.ParameterSetName.Equals(WindowsDiskEncryptionParameterSet))
                ? new DiskEncryptionSettings
                {
                    DiskEncryptionKey = new KeyVaultSecretReference
                    {
                        SourceVault = new SourceVaultReference
                        {
                            ReferenceUri = this.DiskEncryptionKeyVaultId
                        },
                        SecretUrl = this.DiskEncryptionKeyUrl
                    },
                    KeyEncryptionKey = (this.KeyEncryptionKeyVaultId == null || this.KeyEncryptionKeyUrl == null)
                    ? null
                    : new KeyVaultKeyReference
                    {
                        KeyUrl = this.KeyEncryptionKeyUrl,
                        SourceVault = new SourceVaultReference
                        {
                            ReferenceUri = this.KeyEncryptionKeyVaultId
                        },
                    }
                }
                : null
            };

            WriteObject(this.VM);
        }
    }
}
