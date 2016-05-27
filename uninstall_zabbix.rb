#!/usr/bin/env ruby
#
# uninstall_zabbix.rb
#
# This script coordinates the uninstall of zabbix from the head nodes.
#
# Provisos:
#
# To use from the command line:
#
#  1. If necessary, configure your local rubygems mirror.
#     Replace 'http://mirror.example.com' with your actual mirror.
#     ```
#     bundle config mirror.https://rubygems.org http://mirror.example.com
#     ```
#
#  2. Run 'bundle install --deployment' on a bootstrap node with
#     access to a rubygems mirror.
#
#  3. If not already using the target bootstrap, sync the updated
#     repository, including 'vendor' directory, to the target
#     bootstrap.
#
#  4. Run 'bundle exec ./uninstall_zabbix.rb -p <mysql root password>
#      ' to begin the process.
#
# It is also possible to use methods from this script at a ruby REPL
# instead of running the script from a UNIX shell.  To load methods
# into `irb`:
#
#  1. Change to the repo directory.
#
#  2. Verify that dependencies are installed:
#     `bundle list`
#
#  3. Run irb inside the repo directory.
#     `bundle exec irb`
#
#  4. Load this file.
#     `irb(main):001:0> load ./uninstall_zabbix.rb`
#

require 'chef/provisioning/transport/ssh'
require 'mixlib/shellout'
require 'pry'
require 'timeout'
require 'optparse'

def get_entry(name)
  parse_cluster_txt.select{ |e| e['runlist'].include?name }.first
end

def get_head_nodes()
  parse_cluster_txt.select{ |e| e['runlist'].include? "Head" }
end

def get_worker_nodes()
  parse_cluster_txt.select{ |e| e['runlist'].include? "Worker" }
end

def is_virtualbox_vm?(entry)
  /^08:00:27/.match(entry['mac_address'])
end

def parse_cluster_txt
  fields = ['hostname',
            'mac_address',
            'ip_address',
            'ilo_address',
            'cobbler_profile',
            'dns_domain',
            'runlist']
  # This is really gross because Ruby 1.9 lacks Array#to_h.
  File.readlines(File.join(repo_dir,"cluster.txt"))
    .map{ |line| Hash[*fields.zip(line.split(' ')).flatten(1)] }
end

def repo_dir
  File.dirname(__FILE__)
end

# Find the Chef environment
def find_chef_env()
  require 'json'
  require 'rubygems'
  require 'ohai'
  require 'mixlib/shellout'
  o = Ohai::System.new
  o.all_plugins

  env_command =
    Mixlib::ShellOut.new('sudo', 'knife',
                         'node', 'show',
                         o[:fqdn] || o[:hostname], '-E',
                         '-f', 'json')
  
  env_command.run_command
  
  if !env_command.status.success?
    raise 'Could not retrieve Chef environment!\n' +
      env_command.stdout + '\n' +
      env_command.stderr
  end
  
  JSON.parse(env_command.stdout)['chef_environment']
end

   
def get_mounted_disks(chef_env, vm_entry)
   c = Mixlib::ShellOut.new('./nodessh.sh', chef_env, vm_entry['hostname'], 'df -h')
   c.run_command
   disks=c.stdout.split("\n") 
   disks = disks[1..disks.length]
   # return all disks mapped to /disk/#
   return disks.map{ |disk| disk.split(" ")[-1]  }.map{|disk| /\/disk\/\d+/.match(disk) == nil ? nil : disk}.compact
end
   
def unmount_disks(chef_env, vm_entry)
   puts 'Unmounting disks.'
   get_mounted_disks(chef_env, vm_entry).each do |disk|
      puts 'unmounting ' + disk
      c = Mixlib::ShellOut.new('./nodessh.sh', chef_env, vm_entry['hostname'], 'umount '+disk, 'sudo')
      c.run_command
      if !c.status.success?
        raise 'Could not unmount ' + disk + ' ' + c.stdout + '\n' + c.stderr
      else
        puts 'Unmounted ' + disk
      end
   end
end

def stop_zabbix_server_and_agent(chef_env)
  get_head_nodes.each do |host|
      puts  host["hostname"]
      c = Mixlib::ShellOut.new('./nodessh.sh', chef_env, host["hostname"], 'service zabbix-agent stop', 'sudo')
      c.run_command
      if !c.status.success?
        puts 'Could not stop zabbix agent on ' + host["hostname"] + ' ' + c.stdout + '\n' + c.stderr
      else
        puts 'Stopped zabbix agent on ' + host["hostname"] 
      end
      confirm_service_down(chef_env, host, "zabbix-agent")
      c = Mixlib::ShellOut.new('./nodessh.sh', chef_env, host["hostname"], 'service zabbix-server stop', 'sudo')
      c.run_command
      if !c.status.success?
        puts 'Could not stop zabbix server on ' + host["hostname"] + ' ' + c.stdout + '\n' + c.stderr
      else
        puts 'Stopped zabbix server on ' + host["hostname"] 
      end
      confirm_service_down(chef_env, host, "zabbix-server")
  end
end

def uninstall_zabbix_api_gem(chef_env)
  get_head_nodes.each do |host|
      puts  host["hostname"]
      c = Mixlib::ShellOut.new('./nodessh.sh', chef_env, host["hostname"], '/opt/chef/embedded/bin/gem uninstall zabbixapi', 'sudo')
      c.run_command
      if !c.status.success?
        puts 'Could not uninstall zabbix api gem on' + host["hostname"] + ' ' + c.stdout + '\n' + c.stderr
      else
        puts 'Uninstalled zabbix api gem on ' + host["hostname"] 
      end
  end
end

def uninstall_zabbix(chef_env)
  commands = [
	'find /etc/ -name *zabbix* -exec rm -f {} \;' ,
	'find /var/spool/ -name *zabbix* -exec rm -f {} \;',
	'find /var/log/ -name *zabbix* -exec rm -f {} \;' ,
	'find /usr/local/ -name *zabbix* -exec rm -f {} \;',
	'rm -rf /var/log/zabbix',
	'rm -rf /usr/local/etc/zabbix_agent.conf.d',
	'rm -rf /usr/local/etc/zabbix_server.conf.d',
	'rm -rf /usr/local/etc/zabbix_agentd.conf.d',
	'rm -rf /usr/local/share/zabbix']
  get_head_nodes.each do |host|
    puts  host["hostname"]
    commands.each do |cmd|
      c = Mixlib::ShellOut.new('./nodessh.sh', chef_env, host["hostname"], cmd, 'sudo')
      c.run_command
    end
  end
end

def drop_zabbix_database(chef_env, vm_entry, password)
      mysqlcmd="mysql -uroot -p"+password+" -e 'show databases;'"
      c = Mixlib::ShellOut.new('./nodessh.sh', chef_env, vm_entry["hostname"], mysqlcmd, 'sudo')
      c.run_command
      if !c.status.success?
        raise 'Could not retrieve current databases' + ' ' + c.stdout + '\n' + c.stderr
      else
          output=c.stdout
          puts output
          if output.include? "zabbix"
        	puts 'Need to drop zabbix table'
          else
                puts 'Zabbix table already gone'
                return
          end
      end
      mysqlcmd="mysql -uroot -p"+password+" -e 'drop database zabbix;'"
      c = Mixlib::ShellOut.new('./nodessh.sh', chef_env, vm_entry["hostname"], mysqlcmd, 'sudo')
      c.run_command
      if !c.status.success?
        raise 'Could not drop zabbix database ' + ' ' + c.stdout + '\n' + c.stderr
      else
        puts 'Dropped zabbix database'
      end
end

def confirm_service_down(chef_env, vm_entry, service)
  #
  # If it takes more than 2 minutes
  # something is really broken.
  #
  # This will make 30 attempts with a 1 minute sleep between attempts,
  # or timeout after 31 minutes.
  #
  command = "ps -ef | grep " + service + " | grep -v grep"
  Timeout::timeout(120) do
    max = 5
    1.upto(max) do |idx|
      c = Mixlib::ShellOut.new('./nodessh.sh', chef_env, vm_entry['hostname'], command )
      c.run_command
      if c.exitstatus == 1 and c.stdout == ''
        puts service + " is down"
        return
      else
        puts "Waiting for " + service + " to go down (attempt #{idx}/#{max})"
        sleep 30
      end
    end
  end
  raise "Could not bring down " + service
end

def kill_chef_client(chef_env, vm_entry)
  puts 'Stopping chef-client'
  ['service chef-client stop ',
   'pkill -f chef-client'].each do |command|
      c = Mixlib::ShellOut.new('./nodessh.sh', chef_env, vm_entry['hostname'], command, 'sudo')
      c.run_command
   end
   confirm_chef_client_down(chef_env, vm_entry)
   puts "Chef client is down"
end

#
# This conditional allows us to use the methods into irb instead of
# invoking the script from a UNIX shell.
#
if __FILE__ == $PROGRAM_NAME

  options = { }
  parser = OptionParser.new do|opts|
	opts.banner = "Usage: uninstall_zabbix.rb [options]"

	opts.on('-p password', '--password=password', 'mysql password') do |password|
		options[:mysqlpassword] = password
	end
	opts.on('-h', '--help', 'Displays Help') do
		puts opts
		exit
	end
  end
 
  parser.parse!

  if options[:mysqlpassword].nil?
    puts parser
    exit(-1)
  end

  vm_entry = get_entry("BCPC-Hadoop-Head-Namenode")

  if vm_entry.nil?
    puts "'#{options[:machine]}' was not found in cluster.txt!"
    exit(-1)
  end

  chef_env = find_chef_env
  stop_zabbix_server_and_agent(chef_env)
  drop_zabbix_database(chef_env, vm_entry, options[:mysqlpassword])
  uninstall_zabbix_api_gem(chef_env)
  uninstall_zabbix(chef_env)

end
