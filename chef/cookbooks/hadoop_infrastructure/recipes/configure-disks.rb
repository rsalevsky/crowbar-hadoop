#
# Cookbook Name: hadoop_infrastructure
# Recipe: configure-disks.rb
#
# Copyright (c) 2011 Dell Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#######################################################################
# Begin recipe
#######################################################################
debug = node[:hadoop_infrastructure][:debug]
Chef::Log.info("HI - BEGIN hadoop_infrastructure:configure-disks") if debug

fs_type = node[:hadoop_infrastructure][:os][:fs_type]

node[:hadoop_infrastructure][:devices] = []
node[:hadoop_infrastructure][:hdfs][:hdfs_mounts] = []

#######################################################################
# Version dependant drive setup code.
#######################################################################

#----------------------------------------------------------------------
# Find all the storage type disks (Hadoop 2.3 or lower).
#----------------------------------------------------------------------
=begin
to_use_disks = []
all_disks = node[:crowbar][:disks]
boot_disk=File.readlink("/dev/#{node[:crowbar_wall][:boot_device]}").split('/')[-1] rescue "sda"
if !all_disks.nil?
  all_disks.each { |k,v|
    to_use_disks << k unless k == boot_disk
  }
end
=end

#----------------------------------------------------------------------
# Find all the unclaimed disks and claim them (Hadoop 2.4 or higher).
#----------------------------------------------------------------------
BarclampLibrary::Barclamp::Inventory::Disk.unclaimed(node).each do |disk|
  if disk.claim("Cloudera")
    Chef::Log.info("Claiming #{disk.name} for Cloudera")
  else
    Chef::Log.info("Failed to claim #{disk.name} for Cloudera")
  end
end

# Use all the disks claimed by Cloudera on this node.

to_use_disks = BarclampLibrary::Barclamp::Inventory::Disk.claimed(node,"Cloudera").map do |d|
  d.device
  end.sort

#----------------------------------------------------------------------
# End of version dependant drive setup code.
#----------------------------------------------------------------------

# Get the disk UUID.
def get_uuid(disk)
  uuid=nil
  IO.popen("blkid -c /dev/null -s UUID -o value #{disk}"){ |f|
    uuid=f.read.strip
  }
  uuid
end

Chef::Log.info("HI - found disk: #{to_use_disks.join(':')} fs_type: [#{fs_type}]") if debug

# Walk over each of the disks, configuring it if required.
wait_for_format = false
found_disks = []
to_use_disks.sort.each { |k|
  # By default, we will format first partition.
  target_suffix= k + "1"
  target_dev = "/dev/#{k}"
  target_dev_part = "/dev/#{target_suffix}"

  # Protect against OS's that confuse ohai. if the device isn't there,
  # don't try to use it.
  if not File.exists?(target_dev)
    Chef::Log.warn("HI - device: #{target_dev} doesn't seem to exist. ignoring")
    next
  end
  disk = Hash.new
  disk[:pid] = 0
  disk[:valid] = true
  disk[:name] = target_dev_part

  # Make sure that the kernel is aware of the current state of the
  # drive partition tables.
  ::Kernel.system("partprobe #{target_dev}")
  # Let udev catch up, if needed.
  sleep 3

  # Create the first partition on the disk if it does not already exist.
  # This takes barely any time, so don't bother parallelizing it.
  # Create the first partition starting at 1MB into the disk, and use GPT.
  # This ensures that it is optimally aligned from an RMW cycle minimization
  # standpoint for just about everything - RAID stripes, SSD erase blocks,
  # 4k sector drives, you name it, and we can have >2TB volumes.
  unless ::Kernel.system("grep -q \'#{target_suffix}$\' /proc/partitions")
    Chef::Log.info("HI - Creating hadoop partition on #{target_dev}")
    ::Kernel.system("parted -s #{target_dev} -- unit s mklabel gpt mkpart primary ext2 2048s -1M")
    ::Kernel.system("partprobe #{target_dev}")
    sleep 3
    ::Kernel.system("dd if=/dev/zero of=#{target_dev_part} bs=1024 count=65")
  end

  # Check to see if there is a volume on the first partition of the
  # drive. If not, fork and exec our disk formatter.
  if ::Kernel.system("blkid -c /dev/null #{target_dev_part} &>/dev/null")
    # This filesystem already exists. Save the UUID for later.
    disk[:uuid]=get_uuid target_dev_part
  else
    Chef::Log.info("HI - formatting #{target_dev_part}") if debug
    ::Kernel.exec "mkfs.#{fs_type} #{target_dev_part}" unless pid = ::Process.fork
    disk[:fresh] = true
    disk[:pid] = pid
    wait_for_format = true
    Chef::Log.info("HI - format exec #{pid} #{target_dev_part}") if debug
  end
  found_disks << disk.dup
}

# Wait for formatting to finish.
if wait_for_format
  Chef::Log.info("HI - Waiting on all drives to finish formatting") if debug
  pstatus = ::Process.waitall
  # Loop through all the formatting processes and make sure they completed successfully.
  # Mark any format failures as being invalid.
  pstatus.each { |pobj|
    pid = 0
    is_ok = false
    if pobj
      pid = pobj[0]
      stat = pobj[1]
      if stat and stat.exited? and stat.exitstatus == 0
        is_ok = true
      end
    end
    Chef::Log.info("HI - format status PID:#{pid} status:#{is_ok}") if debug
    if !is_ok
      found_disks.each { |disk|
        if pid == disk[:pid]
          disk[:valid] = false
          Chef::Log.info("HI - disk format failed for #{disk[:name]}") if debug
        end
      }
    end
  }
end

# Setup the mount points.
# Storage disk mount point are named as follows - /data/N for N = 1, 2, 3...
# Hadoop dfs.data.dir entries are named as follows - /data/N/dfs/dn for N = 1, 2, 3...
# Note : Cloudera Manager adds the /dfs/dn to the end after initial mount point
# detection. This matches the default setting in the Cloudera Manager UI.
cnt = 1
dfs_base_dir = node[:hadoop_infrastructure][:hdfs][:dfs_base_dir]
found_disks.each { |disk|
  if disk[:fresh]
    # We just created this filesystem. Grab its UUID and create a mount point.
    disk[:uuid]=get_uuid disk[:name]
    Chef::Log.info("HI - Adding #{disk[:name]} (#{disk[:uuid]}) to the Hadoop configuration.")
    disk[:mount_point]="#{dfs_base_dir}/#{cnt}"
    ::Kernel.system("mkdir -p #{disk[:mount_point]}")
  elsif disk[:uuid]
    # This filesystem already existed.
    # If we did not create a mountpoint for it, print a warning and skip it.
    disk[:mount_point]="#{dfs_base_dir}/#{cnt}"
    unless ::File.exists?(disk[:mount_point]) and ::File.directory?(disk[:mount_point])
      Chef::Log.warn("HI - #{disk[:name]} (#{disk[:uuid]}) was not created by configure-disks, ignoring.")
      Chef::Log.warn("HI - If you want to use this disk, please erase any data on it and zero the partition information.")
      # Invalidate the mount point array entry.
      disk[:valid] = false
      next
    end
  end

  # Make the HDFS file system mount point.
  if disk[:valid]
    # Mount the storage disks. These directories should be mounted noatime and the
    # disks should be configured JBOD. RAID is not recommended. Example;
    # UUID=b6447526-276d-457a-ad2f-54a5cc8bf450 /data/1 ext3 noatime,nodiratime 0 0
    # UUID=b5210382-750c-4c46-9e36-99baec825023 /data/2 ext3 noatime,nodiratime 0 0
    # UUID=2866e2a0-f191-4493-a080-c031b6bcbd12 /data/3 ext3 noatime,nodiratime 0 0
    mount disk[:mount_point]  do
      device disk[:uuid]
      device_type :uuid
      options "noatime,nodiratime"
      dump 0
      pass 0
      fstype fs_type
      action [:mount, :enable]
    end

    # Update the crowbar data for this node.
    node[:hadoop_infrastructure][:devices] << disk
    node[:hadoop_infrastructure][:hdfs][:hdfs_mounts] << disk[:mount_point]
  end

  cnt += 1
}

# Save the node data.
node.save

#######################################################################
# End recipe
#######################################################################
Chef::Log.info("HI - END hadoop_infrastructure:configure-disks") if debug
