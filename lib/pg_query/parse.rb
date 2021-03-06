require 'json'

class PgQuery
  def self.parse(query)
    tree, stderr = _raw_parse(query)

    begin
      tree = JSON.parse(tree, max_nesting: 1000)
    rescue JSON::ParserError
      raise ParseError.new('Failed to parse JSON', __FILE__, __LINE__, -1)
    end

    warnings = []
    stderr.each_line do |line|
      next unless line[/^WARNING/]
      warnings << line.strip
    end

    PgQuery.new(query, tree, warnings)
  end

  attr_reader :query
  attr_reader :tree
  attr_reader :warnings

  def initialize(query, tree, warnings = [])
    @query = query
    @tree = tree
    @warnings = warnings
  end

  def tables
    load_tables_and_aliases! if @tables.nil?
    @tables
  end

  def cte_names
    load_tables_and_aliases! if @cte_names.nil?
    @cte_names
  end

  def aliases
    load_tables_and_aliases! if @aliases.nil?
    @aliases
  end

  protected

  def load_tables_and_aliases! # rubocop:disable Metrics/CyclomaticComplexity
    @tables = []
    @cte_names = []
    @aliases = {}

    statements = @tree.dup
    from_clause_items = []
    subselect_items = []

    loop do
      statement = statements.shift
      if statement
        case statement.keys[0]
        when SELECT_STMT
          if statement[SELECT_STMT]['op'] == 0
            (statement[SELECT_STMT][FROM_CLAUSE_FIELD] || []).each do |item|
              if item[RANGE_SUBSELECT]
                statements << item[RANGE_SUBSELECT]['subquery']
              else
                from_clause_items << item
              end
            end

            # CTEs
            with_clause = statement[SELECT_STMT]['withClause']
            if with_clause
              with_clause[WITH_CLAUSE]['ctes'].each do |item|
                next unless item[COMMON_TABLE_EXPR]
                @cte_names << item[COMMON_TABLE_EXPR]['ctename']
                statements << item[COMMON_TABLE_EXPR]['ctequery']
              end
            end
          elsif statement[SELECT_STMT]['op'] == 1
            statements << statement[SELECT_STMT]['larg'] if statement[SELECT_STMT]['larg']
            statements << statement[SELECT_STMT]['rarg'] if statement[SELECT_STMT]['rarg']
          end
        when INSERT_STMT, UPDATE_STMT, DELETE_STMT, VACUUM_STMT, COPY_STMT, ALTER_TABLE_STMT, CREATE_STMT, INDEX_STMT, RULE_STMT, CREATE_TRIG_STMT
          from_clause_items << statement.values[0]['relation']
        when VIEW_STMT
          from_clause_items << statement[VIEW_STMT]['view']
          statements << statement[VIEW_STMT]['query']
        when REFRESH_MAT_VIEW_STMT
          from_clause_items << statement[REFRESH_MAT_VIEW_STMT]['relation']
        when EXPLAIN_STMT
          statements << statement[EXPLAIN_STMT]['query']
        when CREATE_TABLE_AS_STMT
          if statement[CREATE_TABLE_AS_STMT]['into'] && statement[CREATE_TABLE_AS_STMT]['into'][INTO_CLAUSE]['rel']
            from_clause_items << statement[CREATE_TABLE_AS_STMT]['into'][INTO_CLAUSE]['rel']
          end
        when LOCK_STMT, TRUNCATE_STMT
          from_clause_items += statement.values[0]['relations']
        when GRANT_STMT
          objects = statement[GRANT_STMT]['objects']
          case statement[GRANT_STMT]['objtype']
          when 0 # Column
            # FIXME
          when 1 # Table
            from_clause_items += objects
          when 2 # Sequence
            # FIXME
          end
        when DROP_STMT
          objects = statement[DROP_STMT]['objects'].map { |list| list.map { |obj| obj['String'] && obj['String']['str'] } }
          case statement[DROP_STMT]['removeType']
          when OBJECT_TYPE_TABLE
            @tables += objects.map { |r| r.join('.') }
          when OBJECT_TYPE_RULE, OBJECT_TYPE_TRIGGER
            @tables += objects.map { |r| r[0..-2].join('.') }
          end
        end

        statement_value = statement.values[0]
        unless statement.empty?
          subselect_items.concat(statement_value['targetList']) if statement_value['targetList']
          subselect_items << statement_value['whereClause'] if statement_value['whereClause']
          subselect_items.concat(statement_value['sortClause'].collect { |h| h[SORT_BY]['node'] }) if statement_value['sortClause']
          subselect_items.concat(statement_value['groupClause']) if statement_value['groupClause']
          subselect_items << statement_value['havingClause'] if statement_value['havingClause']
        end
      end

      next_item = subselect_items.shift
      if next_item
        case next_item.keys[0]
        when A_EXPR
          %w(lexpr rexpr).each do |side|
            elem = next_item.values[0][side]
            next unless elem
            if elem.is_a?(Array)
              subselect_items += elem
            else
              subselect_items << elem
            end
          end
        when BOOL_EXPR
          subselect_items.concat(next_item.values[0]['args'])
        when RES_TARGET
          subselect_items << next_item[RES_TARGET]['val']
        when SUB_LINK
          statements << next_item[SUB_LINK]['subselect']
        end
      end

      break if subselect_items.empty? && statements.empty?
    end

    loop do
      next_item = from_clause_items.shift
      break unless next_item

      case next_item.keys[0]
      when JOIN_EXPR
        %w(larg rarg).each do |side|
          from_clause_items << next_item[JOIN_EXPR][side]
        end
      when ROW_EXPR
        from_clause_items += next_item[ROW_EXPR]['args']
      when RANGE_VAR
        rangevar = next_item[RANGE_VAR]
        next if !rangevar['schemaname'] && @cte_names.include?(rangevar['relname'])

        table = [rangevar['schemaname'], rangevar['relname']].compact.join('.')
        @tables << table
        @aliases[rangevar['alias'][ALIAS]['aliasname']] = table if rangevar['alias']
      end
    end

    @tables.uniq!
  end
end
