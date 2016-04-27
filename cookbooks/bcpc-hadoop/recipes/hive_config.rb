#
# Cookbook Name : bcpc-hadoop
# Recipe Name : hive_config
# Description : To setup hive configuration only. No hive package will be installed through this Recipe
#

#Create hive password
hive_password = make_config('mysql-hive-password', secure_password)

# Hive table stats user
stats_user = make_config('mysql-hive-table-stats-user',
                         node["bcpc"]["hadoop"]["hive"]["hive_table_stats_db_user"])
stats_password = make_config('mysql-hive-table-stats-password', secure_password)

%w{hive webhcat hcat hive-hcatalog}.each do |w|
  directory "/etc/#{w}/conf.#{node.chef_environment}" do
    owner "root"
    group "root"
    mode 00755
    action :create
    recursive true
  end

  bash "update-#{w}-conf-alternatives" do
    code(%Q{
      update-alternatives --install /etc/#{w}/conf #{w}-conf /etc/#{w}/conf.#{node.chef_environment} 50
      update-alternatives --set #{w}-conf /etc/#{w}/conf.#{node.chef_environment}
    })
  end
end

# Set up hive configs
template "/etc/hive/conf/hive-env.sh" do
  source "hv_hive-env.sh.erb"
  mode 0644
  variables(
    :java_home => node[:bcpc][:hadoop][:java],
    :hadoop_heapsize => node[:bcpc][:hadoop][:hive][:env_sh][:HADOOP_HEAPSIZE],
    :hadoop_opts => node[:bcpc][:hadoop][:hive][:env_sh][:HADOOP_OPTS]
  )
end

template "/etc/hive/conf/hive-exec-log4j.properties" do
  source "hv_hive-exec-log4j.properties.erb"
  mode 0644
end

template "/etc/hive/conf/hive-log4j.properties" do
  source "hv_hive-log4j.properties.erb"
  mode 0644
end

hive_site_vars = {
  :is_hive_server => node.run_list.expand(node.chef_environment).recipes.include?("bcpc-hadoop::hive_hcatalog"),
  :mysql_hosts => node[:bcpc][:hadoop][:mysql_hosts].map{ |m| m[:hostname] },
  :zk_hosts => node[:bcpc][:hadoop][:zookeeper][:servers],
  :hive_hosts => node[:bcpc][:hadoop][:hive_hosts],
  :stats_user => stats_user,
  :warehouse => "#{node['bcpc']['hadoop']['hdfs_url']}/user/hive/warehouse",
  :metastore_keytab => "#{node[:bcpc][:hadoop][:kerberos][:keytab][:dir]}/#{node[:bcpc][:hadoop][:kerberos][:data][:hive][:keytab]}",
  :server_keytab => "#{node[:bcpc][:hadoop][:kerberos][:keytab][:dir]}/#{node[:bcpc][:hadoop][:kerberos][:data][:hive][:keytab]}",
  :kerberos_enabled => node[:bcpc][:hadoop][:kerberos][:enable]
}

hive_site_vars[:hive_sql_password] = \
if node.run_list.expand(node.chef_environment).recipes.include?("bcpc-hadoop::hive_hcatalog") then
  hive_password
else
  ""
end

hive_site_vars[:stats_sql_password] = \
if node.run_list.expand(node.chef_environment).recipes.include?("bcpc-hadoop::hive_hcatalog") then
  stats_password
else
  ""
end

hive_site_vars[:metastore_princ] = \
if node.run_list.expand(node.chef_environment).recipes.include?("bcpc-hadoop::hive_hcatalog") then
  "#{node[:bcpc][:hadoop][:kerberos][:data][:hive][:principal]}/#{node[:bcpc][:hadoop][:kerberos][:data][:hive][:princhost] == '_HOST' ? float_host(node[:fqdn]) : node[:bcpc][:hadoop][:kerberos][:data][:hive][:princhost]}@#{node[:bcpc][:hadoop][:kerberos][:realm]}"
else
  "#{node[:bcpc][:hadoop][:kerberos][:data][:hive][:principal]}/#{node[:bcpc][:hadoop][:kerberos][:data][:hive][:princhost] == '_HOST' ? '_HOST' : node[:bcpc][:hadoop][:kerberos][:data][:hive][:princhost]}@#{node[:bcpc][:hadoop][:kerberos][:realm]}"
end

hive_site_vars[:server_princ] = \
if node.run_list.expand(node.chef_environment).recipes.include?("bcpc-hadoop::hive_hcatalog") then
  "#{node[:bcpc][:hadoop][:kerberos][:data][:hive][:principal]}/#{node[:bcpc][:hadoop][:kerberos][:data][:hive][:princhost] == '_HOST' ? float_host(node[:fqdn]) : node[:bcpc][:hadoop][:kerberos][:data][:hive][:princhost]}@#{node[:bcpc][:hadoop][:kerberos][:realm]}"
else
  "#{node[:bcpc][:hadoop][:kerberos][:data][:hive][:principal]}/#{node[:bcpc][:hadoop][:kerberos][:data][:hive][:princhost] == '_HOST' ? '_HOST' : node[:bcpc][:hadoop][:kerberos][:data][:hive][:princhost]}@#{node[:bcpc][:hadoop][:kerberos][:realm]}"
end

template "/etc/hive/conf/hive-site.xml" do
  source "hv_hive-site.xml.erb"
  mode 0644
  variables(:template_vars => hive_site_vars)
end

link "/etc/hive-hcatalog/conf.#{node.chef_environment}/hive-site.xml" do
  to "/etc/hive/conf.#{node.chef_environment}/hive-site.xml"
end

generated_values =
{
 'javax.jdo.option.ConnectionURL' =>
   hive_site_vars[:mysql_hosts].join(',') +
   ':3306/metastore?loadBalanceBlacklistTimeout=5000',
 
 'javax.jdo.option.ConnectionURL' =>
   hive_site_vars[:hive_sql_password],

 'hive.metastore.uris' =>
   hive_site_vars[:hive_hosts]
   .map{ |s| float_host(s[:hostname]) + ":9083" }
   .join(","),

 'hive.zookeeper.quorum' =>
   hive_site_vars[:zk_hosts].map{ |s| float_host(s[:hostname]) }.join(","),

 'hive.metastore.warehouse.dir' =>
   hive_site_vars[:warehouse],

 'hive.stats.dbconnectionstring' =>
   'jdbc:mysql:loadbalance://' + hive_site_vars[:mysql_hosts].join(',') +
   ':3306/hive_table_stats?useUnicode=true' +
   '&characterEncoding=UTF-8' +
   '&user=' + hive_site_vars[:stats_user] +
   '&password=' + hive_site_vars[:stats_sql_password],
}

if hive_site_vars[:kerberos_enabled]
  kerberos_values =
    {
     'hive.metastore.sasl.enabled' => true,
     
     'hive.metastore.kerberos.keytab.file' =>
       hive_site_vars[:metastore_keytab],

     'hive.metastore.kerberos.principal' =>
       hive_site_vars[:metastore_princ]
    }
  generated_values.merge!(kerberos_values)
end

site_xml = node[:bcpc][:hadoop][:hive][:site_xml]

# flatten_hash converts the tree of node object values to a hash with
# dot-notation keys.
environment_values = flatten_hash(site_xml)

# The complete hash for hive_site.xml is a merger of values
# dynamically generated in this recipe, and hardcoded values from the
# environment and attribute files.
complete_hive_site_hash = generated_values.merge(environment_values)

template '/etc/hive/conf/hive-site.fresh.xml' do
  source 'generic_site.xml.erb'
  mode 0644
  variables(:options => complete_hive_site_hash)
end

template "/etc/hive/conf/hive-env.fresh.sh" do
  source "generic_env.sh.erb"
  mode 0644
  variables(:options => node[:bcpc][:hadoop][:hive][:env_sh])
end
