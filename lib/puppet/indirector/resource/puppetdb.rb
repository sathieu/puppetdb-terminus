require 'puppet/indirector/rest'
require 'puppet/util/puppetdb'
require 'json'
require 'uri'

class Puppet::Resource::Puppetdb < Puppet::Indirector::REST
  include Puppet::Util::Puppetdb

  def search(request)
    profile "resource#search" do
      type   = request.key
      host   = request.options[:host]
      filter = request.options[:filter]
      scope  = request.options[:scope]

      # At minimum, we want to filter to the right type of exported resources.
      expr = ['and',
               ['=', 'type', type],
               ['=', 'exported', true],
               ['not',
                 ['=', 'certname', host]]]

      filter_expr = build_expression(filter)
      expr << filter_expr if filter_expr

      query_param = CGI.escape(expr.to_json)

      begin
        url = Puppet::Util::Puppetdb.url_path("/v3/resources?query=#{query_param}")
        response = profile "Resources query: #{URI.unescape(url)}" do
          http_get(request, url, headers)
        end
        log_x_deprecation_header(response)

        unless response.is_a? Net::HTTPSuccess
          # Newline characters cause an HTTP error, so strip them
          raise "[#{response.code} #{response.message}] #{response.body.gsub(/[\r\n]/, '')}"
        end
      rescue => e
        raise Puppet::Error, "Could not retrieve resources from the PuppetDB at #{self.class.server}:#{self.class.port}: #{e}"
      end

      resources = profile "Parse resource query response (size: #{response.body.size})" do
        JSON.load(response.body)
      end

      profile "Build up collected resource objects (count: #{resources.count})" do
        resources.map do |res|
          params = res['parameters'] || {}
          params = params.map do |name,value|
            Puppet::Parser::Resource::Param.new(:name => name, :value => value)
          end
          attrs = {:parameters => params, :scope => scope}
          result = Puppet::Parser::Resource.new(res['type'], res['title'], attrs)
          result.collector_id = "#{res['certname']}|#{res['type']}|#{res['title']}"
          result
        end
      end
    end
  end

  def build_expression(filter)
    return nil unless filter

    lhs, op, rhs = filter

    case op
    when '==', '!='
      build_predicate(op, lhs, rhs)
    when 'and', 'or'
      build_join(op, lhs, rhs)
    else
      raise Puppet::Error, "Operator #{op} in #{filter.inspect} not supported"
    end
  end

  def build_predicate(op, field, value)
    # Title and tag aren't parameters, so we have to special-case them.
    expr = case field
           when "tag"
             # Tag queries are case-insensitive, so downcase them
             ["=", "tag", value.downcase]
           when "title"
             ["=", "title", value]
           else
             ["=", ['parameter', field], value]
           end

    op == '!=' ? ['not', expr] : expr
  end

  def build_join(op, lhs, rhs)
    lhs = build_expression(lhs)
    rhs = build_expression(rhs)

    [op, lhs, rhs]
  end

  def headers
    {'Accept' => 'application/json'}
  end
end
