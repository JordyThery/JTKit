import Foundation

/// The objects of the two demo tenants JamfMigrator copies between:
/// "Contoso Source (Demo)", a golden master with a few objects of every type
/// that refer to each other (a policy with a script, a package, a category,
/// a smart group and a Self Service icon), and "Contoso Destination (Demo)",
/// a fresh tenant with Jamf's built-ins and a few objects already there: one
/// the same as on the source, some that differ, one only there.
public nonisolated enum DemoJamfProObjectSamples {
    public static let sourceHost = "contoso-source.\(DemoNetwork.reservedDomain)"
    public static let destinationHost = "contoso-destination.\(DemoNetwork.reservedDomain)"

    struct Seed {
        var classic: [String: [(Int, String)]] = [:]
        var pro: [String: [[String: Any]]] = [:]
        var settings: [String: [String: Any]] = [:]
        var icons: [(Int, (name: String, data: Data))] = []
    }

    /// A tiny image standing in for an icon; never shown.
    static let iconData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==") ?? Data()

    private static let noSite = "<site><id>-1</id><name>None</name></site>"

    private static func category(_ id: Int, _ name: String) -> String {
        "<category><id>\(id)</id><name>\(name)</name></category>"
    }

    private static func computerScope(_ groups: [(Int, String)]) -> String {
        "<scope><all_computers>false</all_computers><computers/><computer_groups>"
            + groups.map { "<computer_group><id>\($0.0)</id><name>\($0.1)</name></computer_group>" }.joined()
            + "</computer_groups><buildings/><departments/><exclusions><computers/><computer_groups/></exclusions></scope>"
    }

    private static func mobileScope(_ groups: [(Int, String)]) -> String {
        "<scope><all_mobile_devices>false</all_mobile_devices><mobile_devices/><mobile_device_groups>"
            + groups.map { "<mobile_device_group><id>\($0.0)</id><name>\($0.1)</name></mobile_device_group>" }.joined()
            + "</mobile_device_groups><buildings/><departments/><exclusions><mobile_devices/><mobile_device_groups/></exclusions></scope>"
    }

    /// A configuration profile's payload, escaped as Jamf returns it.
    private static func payloads(_ identifier: String, _ name: String, uuid: String) -> String {
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>"
            + "<key>PayloadDisplayName</key><string>\(name)</string>"
            + "<key>PayloadIdentifier</key><string>\(identifier)</string>"
            + "<key>PayloadType</key><string>Configuration</string>"
            + "<key>PayloadUUID</key><string>\(uuid)</string>"
            + "<key>PayloadVersion</key><integer>1</integer></dict></plist>"
        return "<payloads>\(DemoXML.escape(plist))</payloads>"
    }

    private static let macsSmart = (2, "Contoso – Macs on macOS 26")
    private static let designMacs = (3, "Contoso – Design Macs")
    private static let salesIPads = (2, "Contoso – Sales iPads")
    private static let sharedIPads = (3, "Contoso – Shared iPads")

    // MARK: Contoso Source

    static var source: Seed {
        var seed = Seed()
        seed.classic = [
            "sites": [(1, "<site><id>1</id><name>Contoso HQ</name></site>"),
                      (2, "<site><id>2</id><name>Contoso Field Office</name></site>")],
            "networksegments": [(1, "<network_segment><id>1</id><name>Contoso HQ LAN</name>"
                + "<starting_address>10.20.0.1</starting_address><ending_address>10.20.255.254</ending_address>"
                + "<distribution_server/><distribution_point>Cloud Distribution Point</distribution_point><url/>"
                + "<swu_server>Contoso SUS</swu_server><building>Contoso HQ</building><department/>"
                + "<override_buildings>false</override_buildings><override_departments>false</override_departments></network_segment>")],
            "userextensionattributes": [(1, "<user_extension_attribute><id>1</id><name>Cost Center</name>"
                + "<description>Contoso finance cost center</description><data_type>String</data_type>"
                + "<input_type><type>Text Field</type></input_type></user_extension_attribute>")],
            "ldapservers": [(1, "<ldap_server><connection><id>1</id><name>Contoso Directory</name>"
                + "<hostname>ldap.contoso.example</hostname><server_type>Active Directory</server_type><port>636</port>"
                + "<use_ssl>true</use_ssl><authentication_type>simple</authentication_type><account>"
                + "<distinguished_username>CN=Jamf Bind,OU=Service,DC=contoso,DC=example</distinguished_username>"
                + "<password_sha256 since=\"9.23\">e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855</password_sha256>"
                + "</account><open_close_timeout>15</open_close_timeout><search_timeout>60</search_timeout>"
                + "<referral_response/><use_wildcards>true</use_wildcards></connection></ldap_server>")],
            "accounts/groups": [(1, "<group><id>1</id><name>Contoso Helpdesk</name><access_level>Full Access</access_level>"
                + "<privilege_set>Custom</privilege_set>\(noSite)<privileges><jss_objects><privilege>Read Computers</privilege>"
                + "<privilege>Read Mobile Devices</privilege></jss_objects><jss_settings/><jss_actions/><recon/>"
                + "<casper_admin/><casper_remote/><casper_imaging/></privileges><members/></group>")],
            "users": [
                (1, "<user><id>1</id><name>avery.sample</name><full_name>Avery Sample</full_name>"
                    + "<email>avery.sample@contoso.example</email><email_address>avery.sample@contoso.example</email_address>"
                    + "<phone_number/><position>Designer</position><enable_custom_photo_url>false</enable_custom_photo_url>"
                    + "<custom_photo_url/><ldap_server><id>-1</id><name>None</name></ldap_server><extension_attributes>"
                    + "<extension_attribute><id>1</id><name>Cost Center</name><type>String</type><value>CC-100</value>"
                    + "</extension_attribute></extension_attributes><sites/><links><computers/><mobile_devices/></links></user>"),
                (2, "<user><id>2</id><name>jordan.sample</name><full_name>Jordan Sample</full_name>"
                    + "<email>jordan.sample@contoso.example</email><email_address>jordan.sample@contoso.example</email_address>"
                    + "<phone_number/><position>Sales</position><enable_custom_photo_url>false</enable_custom_photo_url>"
                    + "<custom_photo_url/><ldap_server><id>-1</id><name>None</name></ldap_server><extension_attributes/>"
                    + "<sites/><links><computers/><mobile_devices/></links></user>"),
            ],
            "usergroups": [(1, "<user_group><id>1</id><name>Contoso Designers</name><is_smart>false</is_smart>"
                + "<is_notify_on_change>false</is_notify_on_change>\(noSite)<criteria><size>0</size></criteria>"
                + "<users><size>1</size><user><id>1</id><username>avery.sample</username><full_name>Avery Sample</full_name>"
                + "<phone_number/><email_address>avery.sample@contoso.example</email_address></user></users></user_group>")],
            "directorybindings": [(1, "<directory_binding><id>1</id><name>Contoso AD</name><priority>1</priority>"
                + "<domain>ad.contoso.example</domain><username>jamfbind</username>"
                + "<password_sha256 since=\"9.23\">e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855</password_sha256>"
                + "<computer_ou>OU=Macs,DC=ad,DC=contoso,DC=example</computer_ou><type>Active Directory</type></directory_binding>")],
            "softwareupdateservers": [(1, "<software_update_server><id>1</id><name>Contoso SUS</name>"
                + "<ip_address>sus.contoso.example</ip_address><port>8088</port><set_system_wide>true</set_system_wide>"
                + "</software_update_server>")],
            "advancedcomputersearches": [(1, "<advanced_computer_search><id>1</id><name>Contoso – Macs not seen in 30 days</name>"
                + "<view_as>Standard Web Page</view_as><sort_1/><sort_2/><sort_3/><criteria><size>1</size><criterion>"
                + "<name>Last Check-in</name><priority>0</priority><and_or>and</and_or><search_type>more than x days ago</search_type>"
                + "<value>30</value><opening_paren>false</opening_paren><closing_paren>false</closing_paren></criterion></criteria>"
                + "<display_fields><size>2</size><display_field><name>Computer Name</name></display_field>"
                + "<display_field><name>Last Check-in</name></display_field></display_fields><computers/>\(noSite)</advanced_computer_search>")],
            "advancedusersearches": [(1, "<advanced_user_search><id>1</id><name>Contoso – Designers</name><criteria><size>1</size>"
                + "<criterion><name>Position</name><priority>0</priority><and_or>and</and_or><search_type>is</search_type>"
                + "<value>Designer</value><opening_paren>false</opening_paren><closing_paren>false</closing_paren></criterion>"
                + "</criteria><users/><display_fields><size>1</size><display_field><name>Username</name></display_field>"
                + "</display_fields>\(noSite)</advanced_user_search>")],
            "osxconfigurationprofiles": [
                (1, "<os_x_configuration_profile><general><id>1</id><name>Contoso – Wi-Fi</name>"
                    + "<description>Contoso's office Wi-Fi</description>\(noSite)\(category(1, "Contoso Security"))"
                    + "<distribution_method>Install Automatically</distribution_method><user_removable>false</user_removable>"
                    + "<level>System</level><uuid>\(DemoSamples.uuid(0x5101))</uuid><redeploy_on_update>Newly Assigned</redeploy_on_update>"
                    + payloads("com.contoso.example.wifi", "Contoso – Wi-Fi", uuid: DemoSamples.uuid(0x5101))
                    + "</general>\(computerScope([macsSmart]))<self_service><self_service_display_name/></self_service>"
                    + "</os_x_configuration_profile>"),
                (2, "<os_x_configuration_profile><general><id>2</id><name>Contoso – Screen Saver</name>"
                    + "<description>Locks the screen after 10 minutes</description>\(noSite)\(category(1, "Contoso Security"))"
                    + "<distribution_method>Install Automatically</distribution_method><user_removable>false</user_removable>"
                    + "<level>System</level><uuid>\(DemoSamples.uuid(0x5102))</uuid><redeploy_on_update>Newly Assigned</redeploy_on_update>"
                    + payloads("com.contoso.example.screensaver", "Contoso – Screen Saver", uuid: DemoSamples.uuid(0x5102))
                    + "</general>\(computerScope([designMacs]))<self_service><self_service_display_name/></self_service>"
                    + "</os_x_configuration_profile>"),
            ],
            "mobiledeviceconfigurationprofiles": [(1, "<configuration_profile><general><id>1</id><name>Contoso – iPad Restrictions</name>"
                + "<description>Shared iPad restrictions</description>\(noSite)\(category(1, "Contoso Security"))"
                + "<deployment_method>Install Automatically</deployment_method><redeploy_on_update>Newly Assigned</redeploy_on_update>"
                + "<uuid>\(DemoSamples.uuid(0x5201))</uuid>"
                + payloads("com.contoso.example.restrictions", "Contoso – iPad Restrictions", uuid: DemoSamples.uuid(0x5201))
                + "</general>\(mobileScope([sharedIPads]))</configuration_profile>")],
            "macapplications": [(1, "<mac_application><general><id>1</id><name>Contoso Notes</name><version>4.2</version>"
                + "<is_free>true</is_free><bundle_id>com.contoso.example.notes</bundle_id>"
                + "<url>https://apps.contoso.example/notes</url>\(category(2, "Contoso Apps"))\(noSite)</general>"
                + "\(computerScope([designMacs]))<self_service><install_button_text>Get</install_button_text>"
                + "<self_service_description>Contoso's note-taking app</self_service_description></self_service>"
                + "<vpp><assign_vpp_device_based_licenses>true</assign_vpp_device_based_licenses>"
                + "<vpp_admin_account_id>1</vpp_admin_account_id></vpp></mac_application>")],
            "mobiledeviceapplications": [(1, "<mobile_device_application><general><id>1</id><name>Contoso Field App</name>"
                + "<display_name>Contoso Field</display_name><bundle_id>com.contoso.example.field</bundle_id><version>2.8</version>"
                + "<internal_app>false</internal_app><itunes_store_url>https://apps.contoso.example/field</itunes_store_url>"
                + "\(category(2, "Contoso Apps"))\(noSite)<deploy_automatically>true</deploy_automatically></general>"
                + "\(mobileScope([salesIPads]))<self_service><self_service_description>Contoso's field app</self_service_description>"
                + "</self_service></mobile_device_application>")],
            "ebooks": [(1, "<ebook><general><id>1</id><name>Contoso Employee Handbook</name><author>Contoso HR</author>"
                + "<version>3</version><free>true</free><url>https://books.contoso.example/handbook</url>"
                + "\(category(2, "Contoso Apps"))\(noSite)<deployment_method>Make Available in Self Service</deployment_method>"
                + "</general>\(computerScope([macsSmart]))</ebook>")],
            "classes": [(1, "<class><id>1</id><name>Contoso Onboarding Workshop</name><description>First-week workshop</description>"
                + "\(noSite)<source>N/A</source><meeting_times><meeting_time><days>M</days><start_time>900</start_time>"
                + "<end_time>1000</end_time></meeting_time></meeting_times></class>")],
            "restrictedsoftware": [(1, "<restricted_software><general><id>1</id><name>Contoso – Block Torrent Clients</name>"
                + "<process_name>Transmission.app</process_name><match_exact_process_name>true</match_exact_process_name>"
                + "<send_notification>true</send_notification><kill_process>true</kill_process>"
                + "<delete_executable>false</delete_executable><display_message>This app isn't allowed at Contoso.</display_message>"
                + "\(noSite)</general>\(computerScope([macsSmart]))</restricted_software>")],
            "licensedsoftware": [(1, "<licensed_software><general><id>1</id><name>Contoso Design Suite</name>"
                + "<publisher>Contoso Software</publisher><platform>Mac</platform><send_email_on_violation>false</send_email_on_violation>"
                + "<remove_titles_from_inventory_reports>false</remove_titles_from_inventory_reports>\(noSite)</general>"
                + "<software_definitions/><font_definitions/><plugin_definitions/><licenses><size>1</size><license>"
                + "<size>1</size><serial_number_1>ZZDEMO-LIC-0001</serial_number_1><serial_number_2/>"
                + "<organization_name>Contoso</organization_name><registered_to>Contoso IT</registered_to>"
                + "<license_type>Standard</license_type><license_count>25</license_count></license></licenses>"
                + "<attachments/><computers/></licensed_software>")],
            "printers": [(1, "<printer><id>1</id><name>Contoso HQ – 3rd Floor</name><category>Contoso Utilities</category>"
                + "<uri>ipp://printer-3f.contoso.example/ipp/print</uri><CUPS_name>Contoso_HQ_3F</CUPS_name>"
                + "<location>HQ, 3rd floor</location><model>Generic PostScript Printer</model><shared>false</shared>"
                + "<info/><notes/><make_default>false</make_default><use_generic>true</use_generic><ppd/><ppd_path/></printer>")],
            "dockitems": [(1, "<dock_item><id>1</id><name>Contoso Intranet</name><type>App</type>"
                + "<path>file:///Applications/Contoso%20Intranet.app/</path><contents/></dock_item>")],
            "policies": [
                (1, "<policy><general><id>1</id><name>Contoso – Install Notes</name><enabled>true</enabled>"
                    + "<trigger>EVENT</trigger><trigger_checkin>true</trigger_checkin><frequency>Once per computer</frequency>"
                    + "\(category(2, "Contoso Apps"))\(noSite)</general>\(computerScope([macsSmart]))"
                    + "<self_service><use_for_self_service>true</use_for_self_service>"
                    + "<self_service_display_name>Install Contoso Notes</self_service_display_name>"
                    + "<install_button_text>Install</install_button_text>"
                    + "<self_service_icon><id>1</id><filename>contoso-notes.png</filename>"
                    + "<uri>https://\(sourceHost)/iconservlet/?id=1</uri></self_service_icon></self_service>"
                    + "<package_configuration><packages><size>1</size><package><id>1</id><name>ContosoNotes-4.2.pkg</name>"
                    + "<action>Install</action></package></packages></package_configuration>"
                    + "<scripts><size>1</size><script><id>1</id><name>Contoso – Set Dock</name><priority>After</priority>"
                    + "</script></scripts><maintenance><recon>true</recon></maintenance></policy>"),
                (2, "<policy><general><id>2</id><name>Contoso – Update Inventory</name><enabled>true</enabled>"
                    + "<trigger>CHECKIN</trigger><trigger_checkin>true</trigger_checkin><frequency>Once every day</frequency>"
                    + "\(category(3, "Contoso Utilities"))\(noSite)</general>\(computerScope([macsSmart]))"
                    + "<self_service><use_for_self_service>false</use_for_self_service></self_service>"
                    + "<maintenance><recon>true</recon></maintenance></policy>"),
            ],
            "patchpolicies": [(1, "<patch_policy><general><id>1</id><name>Contoso – Chrome updates</name><enabled>true</enabled>"
                + "<target_version>131.0</target_version><release_date>2026-10-01T00:00:00.000Z</release_date>"
                + "<incremental_updates>false</incremental_updates><reboot>false</reboot><minimum_os/><kill_apps/>"
                + "<distribution_method>selfservice</distribution_method><allow_downgrade>false</allow_downgrade>"
                + "<patch_unknown>true</patch_unknown></general>\(computerScope([macsSmart]))"
                + "<user_interaction><install_button_text>Update</install_button_text></user_interaction>"
                + "<software_title_configuration_id>1</software_title_configuration_id></patch_policy>")],
            "webhooks": [(1, "<webhook><id>1</id><name>Contoso – New Mac enrolled</name><enabled>true</enabled>"
                + "<url>https://hooks.contoso.example/jamf/enrolled</url><content_type>application/json</content_type>"
                + "<event>ComputerAdded</event><connection_timeout>5</connection_timeout><read_timeout>2</read_timeout>"
                + "<authentication_type>BASIC</authentication_type><username>jamfhook</username>"
                + "<password_sha256 since=\"10.31\">e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855</password_sha256>"
                + "<enable_display_fields_for_group_object>false</enable_display_fields_for_group_object>"
                + "<display_fields/><smart_group_id>-1</smart_group_id></webhook>")],
        ].merging(patchSources) { first, _ in first }

        seed.pro = [
            "v1/categories": [["id": "1", "name": "Contoso Security", "priority": 9],
                              ["id": "2", "name": "Contoso Apps", "priority": 9],
                              ["id": "3", "name": "Contoso Utilities", "priority": 10]],
            "v1/buildings": [["id": "1", "name": "Contoso HQ", "streetAddress1": "1 Sample Way", "streetAddress2": "",
                              "city": "Example City", "stateProvince": "", "zipPostalCode": "", "country": "Contoso"]],
            "v1/departments": [["id": "1", "name": "Design"], ["id": "2", "name": "Engineering"], ["id": "3", "name": "Sales"]],
            "v1/computer-extension-attributes": [[
                "id": "1", "name": "Contoso Asset Owner", "description": "Who the Mac was handed to", "dataType": "STRING",
                "enabled": true, "inventoryDisplayType": "EXTENSION_ATTRIBUTES", "inputType": "SCRIPT",
                "scriptContents": "#!/bin/zsh\necho \"<result>$(defaults read /Library/Preferences/com.contoso.example.asset Owner 2>/dev/null)</result>\"",
            ]],
            "v1/mobile-device-extension-attributes": [[
                "id": "1", "name": "Contoso Kiosk Mode", "description": "Shared iPads in kiosk mode", "dataType": "STRING",
                "inventoryDisplayType": "GENERAL", "inputType": "POPUP", "popupMenuChoices": ["Yes", "No"],
            ]],
            "v1/scripts": [[
                "id": "1", "name": "Contoso – Set Dock", "info": "Puts Contoso's apps in the Dock", "notes": "",
                "priority": "AFTER", "categoryId": "3", "categoryName": "Contoso Utilities", "osRequirements": "",
                "parameter4": "Contoso Intranet", "scriptContents": "#!/bin/zsh\n# Contoso demo script: adds the intranet to the Dock\nexit 0\n",
            ]],
            "v1/packages": [[
                "id": "1", "packageName": "ContosoNotes-4.2.pkg", "fileName": "ContosoNotes-4.2.pkg", "categoryId": "2",
                "info": "", "notes": "", "priority": 10, "fillUserTemplate": false, "rebootRequired": false,
                "osInstall": false, "suppressUpdates": false, "suppressFromDock": false, "suppressEula": false,
                "suppressRegistration": false, "md5": "", "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
                "hashType": "SHA_256", "hashValue": "", "size": "18432",
            ]],
            "v1/distribution-points": [[
                "id": "1", "name": "Contoso HQ File Share", "serverName": "files.contoso.example", "principal": true,
                "fileSharingConnectionType": "SMB", "shareName": "CasperShare", "workgroup": "CONTOSO",
                "readWriteUsername": "jamfrw", "readOnlyUsername": "jamfro", "httpsEnabled": false,
            ]],
            "v1/accounts": [[
                "id": "1", "username": "avery.sample", "realName": "Avery Sample", "email": "avery.sample@contoso.example",
                "accessLevel": "FullAccess", "privilegeLevel": "CUSTOM", "privileges": ["Read Computers"],
                "siteId": "-1", "accountStatus": "Enabled", "accountType": "DEFAULT", "changePasswordOnNextLogin": false,
            ]],
            "v3/computer-groups/smart-groups": [
                ["id": "1", "name": "All Managed Clients", "description": "", "siteId": "-1", "criteria": [[
                    "name": "Computer Name", "priority": 0, "andOr": "and", "searchType": "like", "value": "",
                    "openingParen": false, "closingParen": false]]],
                ["id": "2", "name": macsSmart.1, "description": "", "siteId": "-1", "criteria": [[
                    "name": "Operating System Version", "priority": 0, "andOr": "and", "searchType": "like", "value": "26.",
                    "openingParen": false, "closingParen": false]]],
            ],
            "v3/computer-groups/static-groups": [["id": "3", "name": designMacs.1, "description": "The design team's Macs",
                                                  "siteId": "-1", "assignments": [["computerId": "1", "selected": true]]]],
            "v2/mobile-device-groups/smart-groups": [
                ["id": "1", "name": "All Managed iPads", "siteId": "-1", "criteria": [[
                    "name": "Model", "priority": 0, "andOr": "and", "searchType": "like", "value": "iPad",
                    "openingParen": false, "closingParen": false]]],
                ["id": "2", "name": salesIPads.1, "siteId": "-1", "criteria": [[
                    "name": "Department", "priority": 0, "andOr": "and", "searchType": "is", "value": "Sales",
                    "openingParen": false, "closingParen": false]]],
            ],
            "v2/mobile-device-groups/static-groups": [["id": "3", "name": sharedIPads.1, "description": "Front desk iPads",
                                                       "siteId": "-1"]],
            "v1/advanced-mobile-device-searches": [[
                "id": "1", "name": "Contoso – iPads on iPadOS 26", "siteId": "-1",
                "criteria": [["name": "OS Version", "priority": 0, "andOr": "and", "searchType": "like", "value": "26.",
                              "openingParen": false, "closingParen": false]],
                "displayFields": ["Display Name", "Serial Number"],
            ]],
            "v3/patch-software-title-configurations": [[
                "id": "1", "displayName": "Google Chrome", "categoryId": "2", "siteId": "-1", "uiNotifications": true,
                "emailNotifications": false, "softwareTitleId": "1", "softwareTitleName": "Google Chrome",
                "softwareTitleNameId": "0BC", "softwareTitlePublisher": "Google", "patchSourceName": "Jamf",
                "patchSourceEnabled": true, "jamfOfficial": true, "extensionAttributes": [] as [Any],
                "packages": [["packageId": "1", "version": "4.2"]],
            ]],
            "v1/app-installers/deployments": [[
                "id": "1", "name": "Contoso – Firefox", "appTitleId": "0C4", "enabled": true,
                "deploymentType": "SELF_SERVICE", "updateBehavior": "AUTOMATIC", "categoryId": "2", "siteId": "-1",
                "smartGroupId": "2", "installPredefinedConfigProfiles": true, "triggerAdminNotifications": false,
                "notificationSettings": ["notificationMessage": "Firefox is ready", "notificationInterval": 1,
                                         "deadlineMessage": "", "deadline": 1, "quitDelay": 1, "completeMessage": "",
                                         "relaunch": true, "suppress": false],
                "selfServiceSettings": ["includeInFeaturedCategory": false, "includeInComplianceCategory": false,
                                        "forceViewDescription": false, "description": "Contoso's browser",
                                        "categories": [["id": "2", "featured": false]]],
            ]],
            "v2/enrollment-customizations": [[
                "id": "1", "displayName": "Contoso Welcome", "description": "Contoso's enrollment screens", "siteId": "-1",
                "enrollmentCustomizationBrandingSettings": ["textColor": "000000", "buttonColor": "0A5AD2",
                                                            "buttonTextColor": "FFFFFF", "backgroundColor": "FFFFFF",
                                                            "iconUrl": ""],
            ]],
            "v3/computer-prestages": [computerPreStage(id: 1, ade: "1", versionLock: 3)],
            "v3/mobile-device-prestages": [mobilePreStage(id: 1, ade: "1", versionLock: 2)],
            "v1/device-enrollments": [["id": "1", "name": "Contoso ABM", "supervisionIdentityId": "-1", "siteId": "-1",
                                       "serverName": "Contoso Jamf Pro (Source)", "serverUuid": DemoSamples.uuid(0x7301),
                                       "tokenExpirationDate": "2027-06-30"]],
        ]
        seed.settings = sourceSettings
        seed.icons = [(1, ("contoso-notes.png", iconData))]
        return seed
    }

    // MARK: Contoso Destination

    static var destination: Seed {
        var seed = Seed()
        seed.classic = [
            // only here: delete mode finds it
            "policies": [(40, "<policy><general><id>40</id><name>Contoso – Old Test Policy</name><enabled>false</enabled>"
                + "<trigger>EVENT</trigger><trigger_checkin>false</trigger_checkin><frequency>Ongoing</frequency>"
                + "\(category(-1, "No category assigned"))\(noSite)</general>\(computerScope([]))"
                + "<self_service><use_for_self_service>false</use_for_self_service></self_service></policy>")],
        ].merging(patchSources) { first, _ in first }
        seed.pro = [
            // the same as on the source, and one that differs
            "v1/categories": [["id": "5", "name": "Contoso Apps", "priority": 9],
                              ["id": "6", "name": "Contoso Security", "priority": 5]],
            // differs from the source: an older version of the script
            "v1/scripts": [[
                "id": "7", "name": "Contoso – Set Dock", "info": "Puts Contoso's apps in the Dock", "notes": "",
                "priority": "AFTER", "categoryId": "-1", "osRequirements": "",
                "parameter4": "", "scriptContents": "#!/bin/zsh\n# Contoso demo script, first version\nexit 0\n",
            ]],
            // Jamf's built-ins on a new tenant
            "v3/computer-groups/smart-groups": [["id": "1", "name": "All Managed Clients", "description": "", "siteId": "-1",
                                                 "criteria": [["name": "Computer Name", "priority": 0, "andOr": "and",
                                                               "searchType": "like", "value": "",
                                                               "openingParen": false, "closingParen": false]]]],
            "v2/mobile-device-groups/smart-groups": [["id": "1", "name": "All Managed iPads", "siteId": "-1",
                                                      "criteria": [["name": "Model", "priority": 0, "andOr": "and",
                                                                    "searchType": "like", "value": "iPad",
                                                                    "openingParen": false, "closingParen": false]]]],
            "v1/device-enrollments": [["id": "4", "name": "Contoso ABM (Destination)", "supervisionIdentityId": "-1",
                                       "siteId": "-1", "serverName": "Contoso Jamf Pro (Destination)",
                                       "serverUuid": DemoSamples.uuid(0x7302), "tokenExpirationDate": "2027-06-30"]],
        ]
        seed.settings = destinationSettings
        return seed
    }

    /// Jamf's own patch source, on every tenant.
    private static let patchSources: [String: [(Int, String)]] = [
        "patchinternalsources": [(1, "<patch_internal_source><id>1</id><name>Jamf</name><is_enabled>true</is_enabled>"
            + "</patch_internal_source>")],
        "patchexternalsources": [],
    ]

    // MARK: PreStages

    private static func computerPreStage(id: Int, ade: String, versionLock: Int) -> [String: Any] {
        [
            "id": "\(id)", "displayName": "Contoso Macs", "mandatory": true, "mdmRemovable": false,
            "supportPhoneNumber": "", "supportEmailAddress": "helpdesk@contoso.example", "department": "",
            "defaultPrestage": false, "enrollmentSiteId": "-1", "keepExistingSiteMembership": false,
            "keepExistingLocationInformation": false, "requireAuthentication": false, "authenticationPrompt": "",
            "preventActivationLock": true, "enableDeviceBasedActivationLock": false,
            "deviceEnrollmentProgramInstanceId": ade,
            "skipSetupItems": ["Location": true, "Privacy": false, "Siri": true],
            "locationInformation": ["id": "\(id)", "username": "", "realname": "", "phone": "", "email": "", "room": "",
                                    "position": "", "departmentId": "-1", "buildingId": "-1", "versionLock": versionLock],
            "purchasingInformation": ["id": "\(id)", "leased": false, "purchased": true, "appleCareId": "", "poNumber": "",
                                      "vendor": "", "purchasePrice": "", "lifeExpectancy": 0, "purchasingAccount": "",
                                      "purchasingContact": "", "leaseDate": "1970-01-01", "poDate": "1970-01-01",
                                      "warrantyDate": "1970-01-01", "versionLock": versionLock],
            "accountSettings": ["id": "\(id)", "payloadConfigured": true, "localAdminAccountEnabled": true,
                                "adminUsername": "contosoadmin", "hiddenAdminAccount": true, "localUserManaged": false,
                                "userAccountType": "STANDARD", "prefillPrimaryAccountInfoFeatureEnabled": false,
                                "prefillType": "UNKNOWN", "prefillAccountFullName": "", "prefillAccountUserName": "",
                                "preventPrefillInfoFromModification": false, "versionLock": versionLock],
            "anchorCertificates": [] as [Any], "enrollmentCustomizationId": "1", "language": "en", "region": "US",
            "autoAdvanceSetup": false, "installProfilesDuringSetup": true, "prestageInstalledProfileIds": ["1"],
            "customPackageIds": ["1"], "customPackageDistributionPointId": "-2", "enableRecoveryLock": false,
            "recoveryLockPasswordType": "MANAGEMENT", "rotateRecoveryLockPassword": false,
            "profileUuid": DemoSamples.uuid(0x8001), "siteId": "-1", "versionLock": versionLock,
        ]
    }

    private static func mobilePreStage(id: Int, ade: String, versionLock: Int) -> [String: Any] {
        [
            "id": "\(id)", "displayName": "Contoso iPads", "mandatory": true, "mdmRemovable": false,
            "supportPhoneNumber": "", "supportEmailAddress": "helpdesk@contoso.example", "department": "",
            "defaultPrestage": false, "enrollmentSiteId": "-1", "keepExistingSiteMembership": false,
            "keepExistingLocationInformation": false, "requireAuthentication": false, "authenticationPrompt": "",
            "preventActivationLock": true, "enableDeviceBasedActivationLock": false,
            "deviceEnrollmentProgramInstanceId": ade, "skipSetupItems": ["Location": true, "Siri": true],
            "locationInformation": ["id": "\(id)", "username": "", "realname": "", "phone": "", "email": "", "room": "",
                                    "position": "", "departmentId": "-1", "buildingId": "-1", "versionLock": versionLock],
            "purchasingInformation": ["id": "\(id)", "leased": false, "purchased": true, "appleCareId": "", "poNumber": "",
                                      "vendor": "", "purchasePrice": "", "lifeExpectancy": 0, "purchasingAccount": "",
                                      "purchasingContact": "", "leaseDate": "1970-01-01", "poDate": "1970-01-01",
                                      "warrantyDate": "1970-01-01", "versionLock": versionLock],
            "anchorCertificates": [] as [Any], "enrollmentCustomizationId": "0", "language": "en", "region": "US",
            "autoAdvanceSetup": false, "allowPairing": true, "multiUser": false, "supervised": true,
            "maximumSharedAccounts": 10, "configureDeviceBeforeSetupAssistant": false,
            "prestageInstalledProfileIds": ["1"], "profileUuid": DemoSamples.uuid(0x8101), "siteId": "-1",
            "versionLock": versionLock,
        ]
    }

    // MARK: Settings

    private static var sourceSettings: [String: [String: Any]] { [
        "v3/check-in": ["checkInFrequency": 15, "createStartupScript": true, "logStartupEvent": true,
                        "checkForPoliciesAtStartup": true, "applyComputerLevelManagedPrefs": false,
                        "ensureSshIsEnabled": false, "createLoginLogoutHooks": true, "logUsername": true,
                        "checkForPoliciesAtLoginLogout": true, "applyUserLevelManagedPreferences": false,
                        "hideRestorePartition": false, "performLoginActionsInBackground": false,
                        "displayStatusToUser": false],
        "v2/computer-inventory-collection-settings": ["computerInventoryCollectionPreferences": [
            "monitorApplicationUsage": true, "includeFonts": false, "includePlugins": false, "includePackages": true,
            "includeSoftwareUpdates": true, "includeSoftwareId": true, "includeAccounts": true,
            "calculateSizes": false, "includeHiddenAccounts": false, "includePrinters": true, "includeServices": true,
            "collectSyncedMobileDeviceInfo": false, "updateLdapInfoOnComputerInventorySubmissions": false,
            "monitorBeacons": false, "allowChangingUserAndLocation": true, "useUnixUserPaths": true,
            "collectUnmanagedCertificates": true,
        ]],
        "v2/smtp-server": ["enabled": true, "authenticationType": "BASIC",
                           "connectionSettings": ["host": "smtp.contoso.example", "port": 587,
                                                  "encryptionType": "TLS_1_2", "connectionTimeout": 5],
                           "senderSettings": ["displayName": "Contoso Jamf", "emailAddress": "jamf@contoso.example"],
                           "basicAuthCredentials": ["username": "jamf@contoso.example"]],
        "v1/self-service/settings": ["installSettings": ["installAutomatically": true, "installLocation": "/Applications"],
                                     "loginSettings": ["userLoginLevel": "Anonymous", "allowRememberMe": false,
                                                       "useFido2": false, "authType": "Basic"],
                                     "configurationSettings": ["notificationsEnabled": true, "alertUserApprovedMdm": true,
                                                               "defaultLandingPage": "HOME", "defaultHomeCategoryId": -1,
                                                               "bookmarksName": "Contoso Links"]],
        "v1/reenrollment": ["isFlushPolicyHistoryEnabled": false, "isFlushLocationInformationEnabled": false,
                            "isFlushLocationInformationHistoryEnabled": false, "isFlushExtensionAttributesEnabled": true,
                            "isFlushSoftwareUpdatePlansEnabled": false,
                            "flushMDMQueue": "DELETE_EVERYTHING_EXCEPT_ACKNOWLEDGED"],
        "v2/local-admin-password/settings": ["autoDeployEnabled": true, "passwordRotationTime": 3600,
                                             "autoRotateEnabled": true, "autoRotateExpirationTime": 7_776_000],
        "v1/onboarding": ["id": "1", "enabled": false, "onboardingItems": [] as [Any]],
        "v3/sso": ["ssoEnabled": false, "configurationType": "SAML", "ssoForEnrollmentEnabled": false,
                   "ssoBypassAllowed": false, "ssoForMacOsSelfServiceEnabled": false, "enrollmentSsoForAccountDrivenEnrollmentEnabled": false,
                   "groupEnrollmentAccessEnabled": false, "userAttributeEnabled": false, "sessionTimeout": 480],
    ] }

    /// A new tenant's defaults: some settings differ from the source, some don't.
    private static var destinationSettings: [String: [String: Any]] {
        var settings = sourceSettings
        settings["v3/check-in"]?["checkInFrequency"] = 30
        settings["v2/smtp-server"] = ["enabled": false, "authenticationType": "NONE",
                                      "connectionSettings": ["host": "", "port": 25, "encryptionType": "NONE",
                                                             "connectionTimeout": 5],
                                      "senderSettings": ["displayName": "Jamf Pro Server", "emailAddress": ""]]
        settings["v1/self-service/settings"]?["configurationSettings"] = [
            "notificationsEnabled": true, "alertUserApprovedMdm": true, "defaultLandingPage": "HOME",
            "defaultHomeCategoryId": -1, "bookmarksName": "Bookmarks"]
        settings["v2/local-admin-password/settings"]?["autoRotateEnabled"] = false
        return settings
    }
}
