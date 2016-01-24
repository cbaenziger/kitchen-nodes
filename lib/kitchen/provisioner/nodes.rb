# -*- encoding: utf-8 -*-
#
# Author:: Matt Wrock (<matt@mattwrock.com>)
#
# Copyright (C) 2015, Matt Wrock
#
# Licensed under the Apache License, Version 2.0 (the 'License');
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an 'AS IS' BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'kitchen'
require 'kitchen/provisioner/chef_zero'
require 'kitchen/provisioner/finder'
require 'kitchen/provisioner/run_list_expansion_from_kitchen'
require 'net/ping'
require 'chef/run_list'
require 'stringio'

module Kitchen
  module Provisioner
    # Nodes provisioner for Kitchen.
    #
    # @author Matt Wrock <matt@mattwrock.com>
    class Nodes < ChefZero

      def create_sandbox
        FileUtils.rm(node_file) if File.exist?(node_file)
        create_node(JSON.pretty_generate(node_template))

      ensure
        super
      end

      def cleanup_sandbox
        FileUtils.rm(node_file) if File.exist?(node_file)
        create_node(read_remote_node_file)
      ensure
        super
      end

      def create_node(node_data)
        FileUtils.mkdir_p(node_dir) unless Dir.exist?(node_dir)
        File.open(node_file, 'w') do |out|
          out << node_data
        end
      end

      def state_file
        @state_file ||= Kitchen::StateFile.new(
          config[:kitchen_root],
          instance.name
        ).read
      end

      def ipaddress
        state = state_file

        if %w(127.0.0.1 localhost).include?(state[:hostname])
          return get_reachable_guest_address(state)
        end
        state[:hostname]
      end

      def fqdn
        state = state_file
        begin
          [:username, :password].each do |prop|
            state[prop] = instance.driver[prop] if instance.driver[prop]
          end
          Finder.for_transport(instance.transport, state).find_fqdn
        rescue
          nil
        end
      end

      def recipes
        rl = config[:run_list].map do |item|
          ::Chef::RunList::RunListItem.new item
        end
        rle = RunListExpansionFromKitchen.new(
          chef_environment,
          rl,
          nil,
          config[:roles_path]
        )
        rle.expand
        rle.recipes
      end

      def chef_environment
        env = '_default'
        if config[:client_rb] && config[:client_rb][:environment]
          env = config[:client_rb][:environment]
        end
        env
      end

      # rubocop:disable Metrics/AbcSize
      def node_template
        {
          id: instance.name,
          chef_environment: chef_environment,
          automatic: {
            ipaddress: ipaddress,
            platform: instance.platform.name.split('-')[0].downcase,
            fqdn: fqdn,
            recipes: recipes
          },
          normal: config[:attributes],
          run_list: config[:run_list]
        }
      end
      # rubocop:enable Metrics/AbcSize

      def node_dir
        File.join(config[:test_base_path], 'nodes')
      end

      def node_file
        File.join(node_dir, "#{instance.name}.json")
      end

      def read_remote_node_file
        state = state_file
        # inject creds into state for legacy drivers
        [:username, :password].each do |prop|
          state[prop] = instance.driver[prop] if instance.driver[prop]
        end
        remote_node_path = "/tmp/kitchen/nodes/#{instance.name}.json"
        puts "XXX #{remote_node_path}"
        node_data = instance.transport.connection(state).download(remote_node_path)
        fail 'Unable to retrieve instance node file' if node_data.empty?
        node_data
      end

      def get_reachable_guest_address(state)
        active_ips(instance.transport, state).each do |address|
          next if address == '127.0.0.1'
          return address if Net::Ping::External.new.ping(address)
        end
      end

      def active_ips(transport, state)
        # inject creds into state for legacy drivers
        [:username, :password].each do |prop|
          state[prop] = instance.driver[prop] if instance.driver[prop]
        end
        ips = Finder.for_transport(transport, state).find_ips
        fail 'Unable to retrieve IPs' if ips.empty?
        ips
      end
    end
  end
end
