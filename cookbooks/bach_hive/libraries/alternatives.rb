require 'poise'
require 'chef/resource'
require 'chef/provider'

# This is a module for a RP that can run update-alternatives
# This makes sure that /etc/alternatives is set correctly
module AlternativesProvider
  # This is the resource class for the provider.  It contains the declaration
  class Resource < Chef::Resource
    include Poise
    provides(:bach_hive_poise_alternatives)
    actions(:create)

    attribute(:component, :kind_of => String)
    attribute(:link_name, :kind_of => String)
  end

  # This is the Provider class for the RP.  It contains the implementation
  class Provider < Chef::Provider
    include Poise
    provides(:bach_hive_poise_alternatives)

    def check_status(c)
      failmsg = "command failed: #{c.stdout}, #{c.stderr}"
      fail failmsg unless c.status.success
      c.exitstatus
    end

    def run_command(command)
      c = Mixlib::ShellOut.new(command)
      c.run_command
      check_status(c)
    end

    def install_alternatives
      run_command('update-alternatives --install' \
                  " /etc/#{new_resource.component}/conf " \
      " #{new_resource.component}-conf " \
        " /etc/#{new_resource.component}/conf.#{new_resource.link_name} 50")
    end

    def update_alternatives
      run_command('update-alternatives --set ' \
                  " #{new_resource.component}-conf " \
                  "/etc/#{new_resource.component}/"\
                  "conf.#{new_resource.link_name}"
                 )
    end

    def action_create
      notifying_block do
        install_alternatives
        update_alternatives
      end
    end
  end
end
