#!/usr/bin/env ruby

require 'pp'
require 'graphviz'
module ThreatSpec
  
  PACKAGE_PATTERN = /^\s*(?:\/\/|\#)\s*ThreatSpec package (?<package>.+?)(?: as (?<alias>.+?))?\s*$/
  FUNCTION_PATTERN = /^\s*(?:\/\/|\#)\s*ThreatSpec (?<model>.+?) for (?<function>.+?)\s*$/
  MITIGATION_PATTERN = /^\s*(?:\/\/|\#)\s*Mitigates (?<component>.+?) against (?<threat>.+?) with (?<mitigation>.+?)\s*(?:\((?<ref>.*?)\))?\s*$/
  EXPOSURE_PATTERN = /^\s*(?:\/\/|\#)\s*Exposes (?<component>.+?) to (?<threat>.+?) with (?<exposure>.+?)\s*(?:\((?<ref>.*?)\))?\s*$/
  DOES_PATTERN = /^\s*(?:\/\/|\#)\s*(?:It|Does|Creates|Returns) (?<action>.+?) for (?<component>.+?)\s*(?:\((?<ref>.*?)\))?\s*$/
  CALLS_PATTERN = /^\s*(?:\/\/|\#)\s*(?:Calls) (?<functions>.+?)\s*$/
  TEST_PATTERN = /^\s*(?:\/\/|\#)\s*Tests (?<function>.+?) for (?<threat>.+?)\s*(?:\((?<ref>.*?)\))?\s*$/
  GO_FUNC_PATTERN = /^\s*func\s+(?<code>(?<function>.+?)\(.*?)\s*{$/
  ZONE_PATTERN = /^(?<zone>.+?):(?<component>.+?)$/
  SENDRECEIVE_PATTERN = /^\s*(?:\/\/|\#)\s*(?<direction>Sends|Receives) (?<subject>.+?) from (?<from_component>.+?) to (?<to_component>.+?)$/
  GRAPH_PATTERN = /^(?<caller>.+?)\t--(?<dynamic>.+?)-(?<line>\d+):(?<column>\d+)-->\t(?<callee>.+?)$/ 
  GRAPH_FUNC_PATTERN = /^\(?\*?(?:(?<path>.+)\/)?(?:(?<package>.+?)\.)?(?<struct>.+?)?\)?\.(?<func>.+?)(?<dynamic>\#\d+)?$/

  def self.parse_component(component)
    if match = ZONE_PATTERN.match(component)
      return [match[:component], match[:zone]]
    else
      return [component, component]
    end
  end
    
  class Package
    attr_accessor :package, :package_alias
    def initialize(package, package_alias, raw)
      @package = package
      @package_alias = package_alias
      @raw = raw
    end
  end

  class Function
    attr_accessor :model, :function, :mitigations, :exposures, :does, :sendreceives, :tests, :raw, :code, :file, :line_number, :package, :callees
    def initialize(model, package, function, raw)
      @model = model
      @function = function
      @mitigations = []
      @exposures = []
      @does = []
      @callees = []
      @sendreceives = []
      @tests = []
      @raw = raw
      @package = package
    end
  end

  class Mitigation
    attr_accessor :threat, :mitigation, :ref, :raw, :component, :zone
    def initialize(component, threat, mitigation, ref, raw)
      (@component, @zone) = ThreatSpec.parse_component(component)
      @threat = threat
      @mitigation = mitigation
      @ref = ref
      @raw = raw
    end
  end

  class Exposure
    attr_accessor :threat, :exposure, :ref, :raw, :component, :zone
    def initialize(component, threat, exposure, ref, raw)
      (@component, @zone) = ThreatSpec.parse_component(component)
      @threat = threat
      @exposure = exposure
      @ref = ref
      @raw = raw
    end
  end

  class Callee
    attr_accessor :callee
    def initialize(callee, raw)
      @callee = callee
      @raw = raw
    end
  end

  class Does
    attr_accessor :action, :ref, :raw, :component, :zone
    def initialize(action, component, ref, raw)
      (@component, @zone) = ThreatSpec.parse_component(component)
      @action = action
      @ref = ref
      @raw = raw
    end
  end

  class SendReceive
    attr_accessor :direction, :subject, :from_component, :to_component, :from_zone, :to_zone
    def initialize(direction, subject, from_component, to_component, raw)
      (@from_component, @from_zone) = ThreatSpec.parse_component(from_component)
      (@to_component, @to_zone) = ThreatSpec.parse_component(to_component)
      @direction = direction.downcase
      @subject = subject
      @raw = raw
    end
  end

  class Test
    attr_accessor :function, :threat, :ref, :raw
    def initialize(function, threat, ref, raw)
      @function = function
      @threat = threat
      @ref = ref
      @raw = raw
    end
  end

  class Parser
    attr_accessor :current_function, :models, :current_package, :debug

    def initialize
      @functions = {}
      @functions_found = {}
      @functions_covered = {}
      @functions_tested = {}
      @debug = false
    end

    def log(msg)
      puts "DEBUG #{msg}" if @debug
    end

    def parse_package(match, line)
      @current_package = Package.new(match[:package], match[:alias], line)
    end

    def parse_function(match, line)
      @current_function = Function.new(match[:model], @current_package, match[:function], line)
    end

    def parse_mitigation(match, line)
      if @current_function
        @functions_covered[@current_function] ||= 0
        @functions_covered[@current_function] += 1
        mitigation = Mitigation.new(match[:component], match[:threat], match[:mitigation], match[:ref], line)
        @current_function.mitigations << mitigation
      else
        log "orphaned: #{line}"
      end
    end

    def parse_exposure(match, line)
      if @current_function
        @functions_covered[@current_function] ||= 0
        @functions_covered[@current_function] += 1
        exposure = Exposure.new(match[:component], match[:threat], match[:exposure], match[:ref], line)
        @current_function.exposures << exposure
      else
        log "orphaned: #{line}"
      end
    end

    def parse_does(match, line)
      if @current_function
        @functions_covered[@current_function] ||= 0
        @functions_covered[@current_function] += 1
        does = Does.new(match[:action], match[:component], match[:ref], line)
        @current_function.does << does
      else
        log "orphaned: #{line}"
      end
    end

    def parse_calls(match, line)
      if @current_function
        @functions_covered[@current_function] ||= 0
        @functions_covered[@current_function] += 1
        match[:functions].split(" ").each do |callee|
          @current_function.callees << Callee.new(callee.gsub(".", ":"), line)
        end
      else
        log "orphaned: #{line}"
      end

    end

    def parse_sendreceive(match, line)
      if @current_function
        @functions_covered[@current_function] ||= 0
        @functions_covered[@current_function] += 1
        sendreceive = SendReceive.new(match[:direction], match[:subject], match[:from_component], match[:to_component], line)
        @current_function.sendreceives << sendreceive
      else
        log "orphaned: #{line}"
      end
    end

    def parse_test(match, line)
      if @current_function
        @functions_tested[match[:function]] ||= 0
        @functions_tested[match[:function]] += 1
        test = Test.new(match[:function], match[:threat], match[:ref], line)
        @current_function.tests << test
      else
        log "orphaned: #{line}"
      end
    end

    def parse_go_function(match, line)
      @functions_found[match[:function]] ||= 0
      @functions_found[match[:function]] += 1
      if @current_function && match[:function].split(' ').last == @current_function.function.split('.').last
        @current_function.code = match[:code]
        @current_function.file = @file
        @current_function.line_number = @line_number
      end
    end

    def parse(file, code)
      @file = file
      @line_number = 1
      @current_package = nil
      @function_scope = false

      log "parsing file #{file}"

      code.each_line do |line|
        line.chomp!
        if match = PACKAGE_PATTERN.match(line)
          parse_package(match, line)
        elsif match = FUNCTION_PATTERN.match(line)
          @function_scope = true
          parse_function(match, line)
        elsif @function_scope && match = MITIGATION_PATTERN.match(line)
          parse_mitigation(match, line)
        elsif @function_scope && match = EXPOSURE_PATTERN.match(line)
          parse_exposure(match, line)
        elsif @function_scope && match = DOES_PATTERN.match(line)
          parse_does(match, line)
        elsif @function_scope && match = SENDRECEIVE_PATTERN.match(line)
          parse_sendreceive(match, line)
        elsif @function_scope && match = TEST_PATTERN.match(line)
          parse_test(match, line)
        elsif match = GO_FUNC_PATTERN.match(line)
          parse_go_function(match, line)
        elsif match = CALLS_PATTERN.match(line)
          parse_calls(match, line)
        else
          @function_scope = false
        end
        @line_number += 1
        if @current_function
          func = @current_function.function
          raw = @current_function.package ? "#{@current_function.package.package}.#{func}" : func
          if match = GRAPH_FUNC_PATTERN.match(raw)
            key = normalize_graph_func(match[:path], match[:package], match[:struct], match[:func])
          end
          @functions[key] = @current_function
        end
      end
    end

    def to_key(x)
      x.downcase.gsub(/[^a-z0-9]/, '')
    end

    def component_key(zone, component) 
      to_key(zone) + "-" + to_key(component)
    end

    def analyze
      @components = {}
      @functions.each_pair do |function_name, function|
        function.mitigations.each do |mitigation|
          ckey = component_key(mitigation.zone, mitigation.component)
          @components[ckey] ||= {:threats => {}, :actions => [], :zone => mitigation.zone, :component => mitigation.component}
          @components[ckey][:threats][mitigation.threat] ||= {:mitigations => [], :exposures => []}
          @components[ckey][:threats][mitigation.threat][:mitigations] << { :mitigation => mitigation, :file => function.file, :line => function.line_number, :function => function_name}
        end

        function.exposures.each do |exposure|
          ckey = component_key(exposure.zone, exposure.component)
          @components[ckey] ||= {:threats => {}, :actions => [], :zone => exposure.zone, :component => exposure.component}
          @components[ckey][:threats][exposure.threat] ||= {:mitigations => [], :exposures => []}
          @components[ckey][:threats][exposure.threat][:exposures] <<  { :exposure => exposure, :file => function.file, :line => function.line_number, :function => function_name}
        end

        function.does.each do |does|
          ckey = component_key(does.zone, does.component)
          @components[ckey] ||= {:threats => {}, :actions => [], :zone => does.zone, :component => does.component}
          @components[ckey][:actions] << does.action
        end
      end
    end

    def summary
      pp @functions
    end

    def report
      num_found = @functions_found.size
      num_covered = @functions_covered.size
      num_tested = @functions_tested.size

      puts "# ThreatSpec Report for ..."
      puts ""
      puts "# Analysis"
        puts "* Functions found: #{num_found}"
        puts "* Functions covered: #{(100*num_covered.to_f/num_found.to_f).round(2)}% (#{num_covered})"
        puts "* Functions tested: #{(100*num_tested.to_f/num_covered.to_f).round(2)}% (#{num_tested})"
      puts ""
      puts "# Components"
      @components.each_pair do |ckey, component|
        puts "## #{component[:zone]} #{component[:component]}"
        component[:threats].each_pair do |threat_name, threat|
          puts "### Threat: #{threat_name}"
          threat[:mitigations].each do |mitigation|
            file = mitigation[:file]
            line = mitigation[:line]
            function = mitigation[:function]
            puts "* Mitigation: #{mitigation[:mitigation].mitigation} (#{function} in #{file}:#{line})"
          end
          threat[:exposures].each do |exposure|
            file = exposure[:file]
            line = exposure[:line]
            function = exposure[:function]
            puts "* Exposure: #{exposure[:exposure].exposure} (#{function} in #{file}:#{line})"
          end
          puts ""
        end
      end
    end

    def normalize_graph_func(path, package, struct, func)
      result = []
      result << path if path
      result << package if package
      result << struct if struct
      result << func

      result.join(':')
    end

    def parse_graph
      @call_graph = {}
      return if STDIN.tty?

      contents = STDIN.read

      return unless contents.size > 0

      contents.each_line do |line|
        if match = GRAPH_PATTERN.match(line)
          if caller_match = GRAPH_FUNC_PATTERN.match(match[:caller])
            caller_name = normalize_graph_func(caller_match[:path], caller_match[:package], caller_match[:struct], caller_match[:func])
          else
            next
          end
          
          if callee_match = GRAPH_FUNC_PATTERN.match(match[:callee])
            callee_name = normalize_graph_func(callee_match[:path], callee_match[:package], callee_match[:struct], callee_match[:func])
          else
            next
          end

          @call_graph[caller_name] ||= {}
          @call_graph[caller_name][callee_name] ||= []
          @call_graph[caller_name][callee_name] << { :line => match[:line], :column => match[:column] }
        end
      end
    end

    def graph

      parse_graph

      threat_graph = {}
      mitigations = {}
      exposures = {}
      sendreceives = []

      @functions.each_pair do |caller_name, caller_function|
        log "looking for caller #{caller_name}"
        caller_function.sendreceives.each do |sr|
          sendreceives << sr
        end

        if graph_caller = @call_graph[caller_name]
          log "found caller #{caller_name}"
          source_components = []

          caller_func = @functions[caller_name]

          caller_func.mitigations.each do |x|
            ckey = component_key(x.zone, x.component)
            source_components << ckey
            mitigations[ckey] ||= 0
            mitigations[ckey] += 1
          end
          caller_func.exposures.each do |x|
            ckey = component_key(x.zone, x.component)
            source_components << ckey
            exposures[ckey] ||= 0
            exposures[ckey] += 1
          end
          caller_func.does.each do |x|
            ckey = component_key(x.zone, x.component)
            source_components << ckey
          end

          source_components.uniq!

          ((caller_func.callees.inject({}) { |h,v| h[v.callee] = 1; h}).merge( graph_caller)).each_pair do |callee_name, graph|
            log "looking for callee #{callee_name} for caller #{caller_name}"
            if @functions.has_key?(callee_name)
              log "found callee #{callee_name}"
              dest_components = []
              mitigations_count = 0
              exposures_count = 0

              callee_func = @functions[callee_name]

              callee_func.mitigations.each do |x|
                ckey = component_key(x.zone, x.component)
                dest_components << ckey
                mitigations[ckey] ||= 0
                mitigations[ckey] += 1
              end
              callee_func.exposures.each do |x|
                ckey = component_key(x.zone, x.component)
                dest_components << ckey
                exposures[ckey] ||= 0
                exposures[ckey] += 1
              end
              callee_func.does.each do |x|
                ckey = component_key(x.zone, x.component)
                dest_components << ckey
              end
              dest_components.uniq!

              source_components.each do |s|
                dest_components.each do |d|
                  if callee_func.package
                    if callee_func.package.package_alias
                      callee_label = "#{callee_func.package.package_alias}.#{callee_func.function.split('.').last}"
                    else
                      callee_label = "#{callee_func.package.package}.#{callee_func.function.split('.').last}"
                    end
                  else
                    callee_name
                  end

                  threat_graph[s] ||= {}
                  threat_graph[s][d] ||= []
                  threat_graph[s][d] << {:callee => callee_label, :mitigations => callee_func.mitigations.size, :exposures => callee_func.exposures.size}
                end
              end
            end
          end
        end
      end

      g = GraphViz.new( :G, :type => :digraph, :overlap => 'false', :nodesep => 0.6, :layout => 'dot', :rankdir => 'LR')
      g["compound"] = "true"
      g.edge["lhead"] = ""
      g.edge["ltail"] = ""

      nodes = {}
      zones = {}

      threat_graph.each_pair do |source, more|
        source_component = @components[source]
        zone = source_component[:zone]

        zone_key = to_key(zone)
        unless zones.has_key?(zone_key)
          zones[zone_key] = g.add_graph("cluster_#{zone_key}")
          zones[zone_key][:label] = zone
          zones[zone_key][:style] = 'dashed'
        end

        unless nodes.has_key?(source)
          nodes[source] = zones[zone_key].add_nodes(source)
          nodes[source][:label] = source_component[:component]

          if exposures.has_key?(source) and exposures[source] > 0
            if mitigations.has_key?(source) and mitigations[source] > 0
              nodes[source][:color] = 'orange'
            else
              nodes[source][:color] = 'red'
            end
          else
            if mitigations.has_key?(source) and mitigations[source] > 0
              nodes[source][:color] = 'darkgreen'
            end
          end
          nodes[source][:shape] = 'box'
        end

        more.each_pair do |dest, funcs|
          dest_component = @components[dest]
          zone = dest_component[:zone]

          zone_key = to_key(zone)
          unless zones.has_key?(zone_key)
            zones[zone_key] = g.add_graph("cluster_#{zone_key}")
            zones[zone_key][:label] = zone
            zones[zone_key][:style] = 'dashed'
          end

          unless nodes.has_key?(dest)
            nodes[dest] = zones[zone_key].add_nodes(dest)
            nodes[dest][:label] = dest_component[:component]
            if exposures.has_key?(dest) and exposures[dest] > 0
              if mitigations.has_key?(dest) and mitigations[dest] > 0
                nodes[dest][:color] = 'orange'
              else
                nodes[dest][:color] = 'red'
              end
            else
              if mitigations.has_key?(dest) and  mitigations[dest] > 0
                nodes[dest][:color] = 'darkgreen'
              end
            end
            nodes[dest][:shape] = 'box'
          end

          label = []
          edge_color = 'black'
          funcs.each do |f|
            if f[:exposures] > 0
              if f[:mitigations] > 0
                color = "orange"
                edge_color = "orange" unless edge_color == "red"
              else
                color = "red"
                edge_color = "red"
              end
            else
              if f[:mitigations] > 0
                color = "darkgreen"
                edge_color = "darkgreen" if edge_color == "black"
              else
                color = "black"
              end
            end
            label << "<font color=\"#{color}\">#{f[:callee]}</font>"
          end

          if funcs.size >= 3
            total = 0
            ne = 0
            nm = 0
            funcs.each do |f|
              total += 1
              ne += f[:exposures]
              nm += f[:mitigations]
            end
            no = total - ne - nm
            label = ["<font color=\"red\">#{ne}</font> / <font color=\"darkgreen\">#{nm}</font> / <font color=\"black\">#{no}</font>"]
          end

          edge = g.add_edges(nodes[source], nodes[dest], :label => "<"+label.uniq.join("<br/>\n")+">", :color => edge_color)
        end
      end

      sendreceives.each do |sr|
        zone_key = to_key(sr.from_zone)
        unless zones.has_key?(zone_key)
          zones[zone_key] = g.add_graph("cluster_#{zone_key}")
          zones[zone_key][:label] = sr.from_zone
          zones[zone_key][:style] = 'dashed'
        end
        from_node_key = component_key(sr.from_zone, sr.from_component)
        unless nodes.has_key?(from_node_key)
          nodes[from_node_key] = zones[zone_key].add_nodes(from_node_key)
          nodes[from_node_key][:label] = sr.from_component
          nodes[from_node_key][:shape] = 'oval'
        end

        zone_key = to_key(sr.to_zone)
        unless zones.has_key?(zone_key)
          zones[zone_key] = g.add_graph("cluster_#{zone_key}")
          zones[zone_key][:label] = sr.to_zone
          zones[zone_key][:style] = 'dashed'
        end

        to_node_key = component_key(sr.to_zone, sr.to_component)
        unless nodes.has_key?(to_node_key)
          nodes[to_node_key] = zones[zone_key].add_nodes(to_node_key)
          nodes[to_node_key][:label] = sr.to_component
          nodes[to_node_key][:shape] = 'oval'
        end

        if sr.direction == 'sends'
          color = 'blue'
        else
          color = 'purple'
        end

        label = ["<font color=\"#{color}\">#{sr.subject}</font>"]
        edge = g.add_edges(nodes[from_node_key], nodes[to_node_key], :label => "<"+label.uniq.join("<br/>\n")+">", :color => color)
      end
      g.output( :png => "threatspec.png" )
    end

  end

end

parser = ThreatSpec::Parser.new
parser.debug = true

ARGV.each do |file| 
  parser.parse file, File.open(file).read
end
parser.analyze
#parser.summary
parser.report
parser.graph
