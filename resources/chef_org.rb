#
# Author:: Nathan Cerny <ncerny@chef.io>
#
# Cookbook:: chef-ingredient
# Resource:: chef_org
#
# Copyright:: 2017-2021, Chef Software, Inc.
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

provides :chef_org
resource_name :chef_org

unified_mode true if respond_to?(:unified_mode)

property :org, String, name_property: true
property :org_full_name, String
property :admins, Array, required: true
property :users, Array, default: []
property :remove_users, Array, default: []
property :key_path, String
property :pivotal_key, String, default: '/etc/opscode/pivotal.pem' # Assumes pivotal key is in the default location
property :client_rb, String, default: '/etc/chef/client.rb'

Chef::Config.from_file("#{client_rb}")
property :chef_server_url, String, default: Chef::Config[:chef_server_url].gsub(%r{/organizations/.*}, '')

# Intialize Chef::Config with pivotal
Chef::Config[:chef_server_url] = "#{chef_server_url}/organizations/#{new_resource.org}"
Chef::Config[:client_name] = 'pivotal'
Chef::Config[:client_key] = pivotal_key
api = Chef::ServerAPI.new(Chef::Config[:chef_server_url])

load_current_value do
  node.run_state['chef-users'] ||= shell_out('chef-server-ctl user-list').stdout
  node.run_state['chef-orgs'] ||= shell_out('chef-server-ctl org-list').stdout
  users.each do |user|
    node.run_state["#{user}_orgs"] ||= JSON.parse(shell_out("chef-server-ctl user-show #{user} -l -F json").stdout.strip)['organizations']
  end
  node.run_state["#{org}_admins"] ||=
  current_value_does_not_exist! unless node.run_state['chef-orgs'].index(/^#{org}$/)
end

action :create do
  directory '/etc/opscode/orgs' do
    owner 'root'
    group 'root'
    mode '0700'
    recursive true
  end

  org_full_name = (property_is_set?(:org_full_name) ? new_resource.org_full_name : new_resource.org)
  key = (property_is_set?(:key_path) ? new_resource.key_path : "/etc/opscode/orgs/#{new_resource.org}-validation.pem")
  execute "create-org-#{new_resource.org}" do
    retries 10
    command "chef-server-ctl org-create #{new_resource.org} '#{org_full_name}' -f #{key}"
    not_if { node.run_state['chef-orgs'].index(/^#{new_resource.org}$/) }
  end

  new_resource.users.each do |user|
    org_user_exist = node.run_state["#{user}_orgs"].include?(new_resource.org)
    execute "add-user-#{user}-org-#{new_resource.org}" do
      command "chef-server-ctl org-user-add #{new_resource.org} #{user}"
      only_if { node.run_state['chef-users'].index(/^#{user}$/) }
      not_if { org_user_exist }
    end
  end

  new_resource.admins.each do |user|
    execute "add-admin-#{user}-org-#{new_resource.org}" do
      command "chef-server-ctl org-user-add --admin #{new_resource.org} #{user}"
      only_if { node.run_state['chef-users'].index(/^#{user}$/) }
      not_if { api.get("organizations/#{new_resource.org}/groups/admins")['users'].include?(user) }
    end
  end

  new_resource.remove_users.each do |user|
    org_user_exist = JSON.parse(shell_out("chef-server-ctl user-show #{user} -l -F json").stdout)['organizations'].include?(new_resource.org)
    execute "remove-user-#{user}-org-#{new_resource.org}" do
      command "chef-server-ctl org-user-remove #{new_resource.org} #{user}"
      only_if { node.run_state['chef-users'].index(/^#{user}$/) }
      only_if { org_user_exist }
    end
  end
end

action_class do
  include ChefIngredientCookbook::Helpers
end
