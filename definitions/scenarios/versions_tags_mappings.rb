SATELLITE_MAPPINGS = { '6.2' => :upgrade_to_satellite_6_2,
                       '6.2.z' => :upgrade_to_satellite_6_2_z,
                       '6.3' => :upgrade_to_satellite_6_3,
                       '6.3.z' => :upgrade_to_satellite_6_3_z,
                       '6.4' => :upgrade_to_satellite_6_4,
                       '6.4.z' => :upgrade_to_satellite_6_4_z,
                       '6.5' => :upgrade_to_satellite_6_5,
                       '6.5.z' => :upgrade_to_satellite_6_5_z,
                       '6.6' => :upgrade_to_satellite_6_6,
                       '6.6.z' => :upgrade_to_satellite_6_6_z }.freeze

CAPSULE_MAPPINGS = {
  '6.7' => :upgrade_to_capsule_6_7,
  '6.7.z' => :upgrade_to_capsule_6_7_z
}.freeze

def pkg_manager
  ForemanMaintain::PackageManager::Yum.new
end

def satellite?
  pkg_manager.installed?('satellite')
end

def capsule?
  pkg_manager.installed?('satellite-capsule')
end

def call_register_version(version, tag)
  ForemanMaintain::UpgradeRunner.register_version(version, tag)
end

if satellite?
  SATELLITE_MAPPINGS.each do |version, tag|
    call_register_version(version, tag)
  end
elsif capsule?
  CAPSULE_MAPPINGS.each do |version, tag|
    call_register_version(version, tag)
  end
end
