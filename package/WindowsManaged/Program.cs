﻿using DevolutionsGateway.Actions;
using DevolutionsGateway.Dialogs;
using DevolutionsGateway.Properties;
using DevolutionsGateway.Resources;
using Microsoft.Deployment.WindowsInstaller;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Windows.Forms;
using System.Xml;
using WixSharp;
using WixSharp.CommonTasks;
using WixSharpSetup.Dialogs;
using Assembly = System.Reflection.Assembly;
using File = WixSharp.File;

namespace DevolutionsGateway;

internal class Program
{
    private const string PackageName = "DevolutionsGateway";

    private static string DevolutionsGatewayExePath
    {
        get
        {
            string path = Environment.GetEnvironmentVariable("DGATEWAY_EXECUTABLE");

            if (string.IsNullOrEmpty(path) || !System.IO.File.Exists(path))
            {
#if DEBUG
                path = "..\\..\\target\\x86_64-pc-windows-msvc\\release\\devolutionsgateway.exe";
#else
                throw new Exception("The environment variable DGATEWAY_EXECUTABLE is not specified or the file does not exist");
#endif
            }

            if (!System.IO.File.Exists(path))
            {
                throw new FileNotFoundException("The gateway executable was not found", path);
            }

            return path;
        }
    }

    private static string DevolutionsGatewayPsModulePath
    {
        get
        {
            string path = Environment.GetEnvironmentVariable("DGATEWAY_PSMODULE_PATH");

            if (string.IsNullOrEmpty(path) || !Directory.Exists(path))
            {
#if DEBUG
                path = "..\\..\\powershell\\DevolutionsGateway";
#else
                throw new Exception("The environment variable DGATEWAY_PSMODULE_PATH is not specified or the directory does not exist");
#endif
            }

            if (!Directory.Exists(path))
            {
                throw new DirectoryNotFoundException("The powershell module was not found");
            }

            return path;
        }
    }

    private static Version DevolutionsGatewayVersion
    {
        get
        {
            string versionString = Environment.GetEnvironmentVariable("DGATEWAY_VERSION");

            if (string.IsNullOrEmpty(versionString) || !Version.TryParse(versionString, out Version version))
            {
#if DEBUG
                versionString = FileVersionInfo.GetVersionInfo(DevolutionsGatewayExePath).FileVersion;

                if (versionString.StartsWith("20"))
                {
                    versionString = versionString.Substring(2);
                }

                version = Version.Parse(versionString);
#else
                throw new Exception("The environment variable DGATEWAY_VERSION is not specified or is invalid");
#endif
            }

            return version;
        }
    }

    private static readonly Dictionary<string, string> Languages = new()
    {
        { "en-US", "DevolutionsGateway_en-us.wxl" },
        { "fr-FR", "DevolutionsGateway_fr-fr.wxl" },
    };

    private static KeyValuePair<string, string> enUS => Languages.First(x => x.Key == "en-US");

    private static KeyValuePair<string, string> frFR => Languages.First(x => x.Key == "fr-FR");

    static void Main()
    {
        ManagedProject project = new(Includes.PRODUCT_NAME)
        {
            UpgradeCode = Includes.UPGRADE_CODE,
            Version = DevolutionsGatewayVersion,
            Description = "!(loc.ProductDescription)",
            InstallerVersion = 500, // Windows Installer 5.0; Server 2008 R2 / Windows 7
            InstallScope = InstallScope.perMachine,
            InstallPrivileges = InstallPrivileges.elevated,
            Platform = Platform.x64,
#if DEBUG
            PreserveTempFiles = true,
            OutDir = "Debug",
#else
            OutDir = "Release",
#endif
            BannerImage = "Resources/WixUIBanner.jpg",
            BackgroundImage = "Resources/WixUIDialog.jpg",
            ValidateBackgroundImage = false,
            OutFileName = PackageName,
            MajorUpgrade = new MajorUpgrade
            {
                AllowDowngrades = false,
                AllowSameVersionUpgrades = true,
                DowngradeErrorMessage = "!(loc.NewerInstalled)",
                Schedule = UpgradeSchedule.afterInstallInitialize,
            },
            Media = new List<Media>
            {
                new()
                {
                    Cabinet = "dgateway.cab",
                    EmbedCab = true,
                    CompressionLevel = CompressionLevel.mszip,
                }
            },
            ControlPanelInfo = new ProductInfo
            {
                Manufacturer = Includes.VENDOR_NAME,
                NoModify = true,
                ProductIcon = "Resources/DevolutionsGateway.ico",
                UrlInfoAbout = Includes.INFO_URL,
            }
        };

        if (CryptoConfig.AllowOnlyFipsAlgorithms)
        {
            project.CandleOptions = "-fips";
        }
        
        project.Dirs = new Dir[]
        {
            new ("%ProgramFiles%", new Dir(Includes.VENDOR_NAME, new InstallDir(Includes.SHORT_NAME)
            {
                Files = new File[]
                {
                    new (DevolutionsGatewayExePath)
                    {
                        TargetFileName = Includes.EXECUTABLE_NAME,
                        FirewallExceptions = new FirewallException[]
                        {
                            new()
                            {
                                Name = Includes.SERVICE_DISPLAY_NAME,
                                Description = $"{Includes.SERVICE_DISPLAY_NAME} TCP",
                                Protocol = FirewallExceptionProtocol.tcp,
                                Profile = FirewallExceptionProfile.all,
                                Scope = FirewallExceptionScope.any,
                                IgnoreFailure = true
                            },
                            new()
                            {
                                Name = Includes.SERVICE_DISPLAY_NAME,
                                Description = $"{Includes.SERVICE_DISPLAY_NAME} UDP",
                                Protocol = FirewallExceptionProtocol.udp,
                                Profile = FirewallExceptionProfile.all,
                                Scope = FirewallExceptionScope.any,
                                IgnoreFailure = true
                            },
                        },
                        ServiceInstaller = new ServiceInstaller()
                        {
                            Type = SvcType.ownProcess,
                            Interactive = false,
                            Vital = true,
                            Name = Includes.SERVICE_NAME,
                            Arguments = "--service",
                            DisplayName = Includes.SERVICE_DISPLAY_NAME,
                            Description = Includes.SERVICE_DISPLAY_NAME,
                            FirstFailureActionType = FailureActionType.restart,
                            SecondFailureActionType = FailureActionType.restart,
                            ThirdFailureActionType = FailureActionType.restart,
                            RestartServiceDelayInSeconds = 900,
                            ResetPeriodInDays = 1,
                            RemoveOn = SvcEvent.Uninstall,
                            StopOn = SvcEvent.InstallUninstall,
                        },
                    },
                },
                Dirs = new Dir[]
                {
                    new ("PowerShell", new Dir("Modules", new Dir("DevolutionsGateway")
                    {
                        Dirs = new Dir[]
                        {
                            new("bin", new Files($@"{DevolutionsGatewayPsModulePath}\bin\*.*")),
                            new("Private", new Files($@"{DevolutionsGatewayPsModulePath}\Private\*.*")),
                            new("Public", new Files($@"{DevolutionsGatewayPsModulePath}\Public\*.*")),
                        },
                        Files = new File[]
                        {
                            new($@"{DevolutionsGatewayPsModulePath}\DevolutionsGateway.psm1"),
                            new($@"{DevolutionsGatewayPsModulePath}\DevolutionsGateway.psd1"),
                        }
                    }))
                }
            })),
        };

        project.Actions = GatewayActions.Actions;
        project.RegValues = new RegValue[]
        {
            new (RegistryHive.LocalMachine, $"Software\\{Includes.VENDOR_NAME}\\{Includes.SHORT_NAME}", "InstallDir", $"[{GatewayProperties.InstallDir}]")
            {
                AttributesDefinition = "Type=string; Component:Permanent=yes",
                Win64 = project.Platform == Platform.x64,
                RegistryKeyAction = RegistryKeyAction.create,
            }
        };
        project.Properties = GatewayProperties.Properties.Select(x => x.ToWixSharpProperty()).ToArray();
        project.ManagedUI = new ManagedUI();
        project.ManagedUI.InstallDialogs.AddRange(Wizard.Dialogs);
        project.ManagedUI.InstallDialogs
            .Add<ProgressDialog>()
            .Add<ExitDialog>();
        project.ManagedUI.ModifyDialogs
            .Add<MaintenanceTypeDialog>()
            .Add<ProgressDialog>()
            .Add<ExitDialog>();
        
        project.UIInitialized += Project_UIInitialized;

        project.Language = enUS.Key;
        project.LocalizationFile = $"Resources/{enUS.Value}";
        project.PreserveTempFiles = true;
        
        string msi = project.BuildMsi();

        project.Language = frFR.Key;
        string mstFile = project.BuildLanguageTransform(msi, project.Language, $"Resources/{frFR.Value}");

        msi.EmbedTransform(mstFile);
        msi.SetPackageLanguages(string.Join(",", Languages.Keys).ToLcidList());
    }

    private static void Project_UIInitialized(SetupEventArgs e)
    {
        string lcid = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "fr" ? frFR.Key : enUS.Key;

        using Stream stream = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream($"DevolutionsGateway.Resources.{Languages[lcid]}");

        XmlDocument xml = new XmlDocument();
        xml.Load(stream);

        Dictionary<string, string> strings = new();

        foreach (XmlNode s in xml.GetElementsByTagName("String"))
        {
            strings.Add(s.Attributes["Id"].Value, s.InnerText);
        }

        if (!Environment.Is64BitOperatingSystem)
        {
            MessageBox.Show($"{strings["x86VersionRequired"]}");

            e.ManagedUI.Shell.ErrorDetected = true;
            e.Result = ActionResult.UserExit;
        }

        Version thisVersion = e.Session.QueryProductVersion();
        Version installedVersion = Helpers.AppSearch.InstalledVersion;

        if (thisVersion < installedVersion)
        {
            MessageBox.Show($"{strings["NewerInstalled"]} ({installedVersion})");

            e.ManagedUI.Shell.ErrorDetected = true;
            e.Result = ActionResult.UserExit;
        }

        e.ManagedUI.OnCurrentDialogChanged += Wizard.DialogChanged;
    }
}