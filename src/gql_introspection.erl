-module(gql_introspection).

-include("gql_schema.hrl").
-include_lib("gql/include/graphql.hrl").

-export([inject/0, augment_root/1]).

%% Resolvers for the introspection
-export([
	schema_resolver/3,
	type_resolver/3,
	schema_types/3,
	query_type/3,
	mutation_type/3,
	subscription_type/3
]).

-spec augment_root(QueryObj) -> ok
  when QueryObj :: binary().

augment_root(QName) ->
    #object_type{ fields = Fields } = Obj = gql_schema:get(QName),
    Schema = #schema_field {
    	ty = {non_null, <<"__Schema">>},
    	description = <<"The introspection schema">>,
    	resolve = fun ?MODULE:schema_resolver/3 },
    Type = #schema_field {
    	ty = <<"__Type">>,
    	description = <<"The introspection type">>,
    	resolve = fun ?MODULE:type_resolver/3,
    	args = #{
    		<<"name">> =>
    		   #schema_arg { ty = {non_null, {scalar, string}}, description = <<"The type to query">> }
         }},
     Augmented = Obj#object_type { fields = Fields#{
         <<"__schema">> => Schema,
         <<"__type">> => Type
     }},
     true = gql_schema:insert(Augmented, #{}),
     ok.
     
schema_resolver(_Ctx, none, #{}) ->
    {ok, #{ <<"directives">> => [] }}.
    
type_resolver(_Ctx, none, #{ <<"name">> := N }) ->
    case gql_schema:lookup(N) of
        not_found -> {ok, null};
        Ty -> {ok, render_type(Ty)}
    end.

query_type(_Ctx, _Obj, _) ->
    #root_schema{ query = QType } = gql_schema:get('ROOT'),
    {ok, render_type(QType)}.

mutation_type(_Ctx, _Obj, _) ->
    #root_schema { mutation = MType } = gql_schema:get('ROOT'),
    case MType of
        undefined -> {ok, null};
        MT -> {ok, render_type(MT)}
    end.

subscription_type(_Ctx, _Obj, _) ->
    #root_schema { subscription = SType } = gql_schema:get('ROOT'),
    case SType of
        undefined -> {ok, null};
        ST -> {ok, render_type(ST)}
    end.

schema_types(_Ctx, _Obj, _Args) ->
    Pass = fun
        (#root_schema{}) -> false;
        (_) -> true
    end,
    Types = [X || X <- gql_schema:all(), Pass(X)],
    {ok, [render_type(Ty) || Ty <- Types]}.

%% Main renderer. Calls out to the subsets needed
render_type(Name) when is_binary(Name) ->
    case gql_schema:lookup(Name) of
        not_found ->
           throw({not_found, Name});
       Ty -> render_type(Ty)
    end;
render_type(Ty) -> #{
    <<"kind">> => type_kind(Ty),
    <<"name">> => type_name(Ty),
    <<"description">> => type_description(Ty),
    <<"fields">> => type_fields(Ty),
    <<"interfaces">> => type_interfaces(Ty),
    <<"possibleTypes">> => type_possibilities(Ty),
    <<"enumValues">> => type_enum_values(Ty),
    <<"inputFields">> => type_input_fields(Ty),
    <<"ofType">> => type_unwrap(Ty) }.

type_kind({scalar, _}) -> <<"SCALAR">>;
type_kind(#scalar_type{}) -> <<"SCALAR">>;
type_kind(#object_type {}) -> <<"OBJECT">>;
type_kind(#input_object_type {}) -> <<"INPUT_OBJECT">>;
type_kind(#interface_type{}) -> <<"INTERFACE">>;
type_kind(#union_type{}) -> <<"UNION">>;
type_kind(#enum_type{}) -> <<"ENUM">>;
type_kind([_Ty]) -> <<"LIST">>;
type_kind({non_null, _Ty}) -> <<"NON_NULL">>.

type_name({scalar, Ty}) -> scalar_name(Ty);
type_name(#scalar_type { id = N }) -> N;
type_name(#enum_type { id = N }) -> N;
type_name(#interface_type { id = N }) -> N;
type_name(#object_type { id = N }) -> N;
type_name(#input_object_type { id = N }) -> N;
type_name(#union_type { id = N }) -> N;
type_name({non_null, _}) -> null;
type_name([_]) -> null.

scalar_name(string) -> <<"String">>;
scalar_name(int) -> <<"Int">>;
scalar_name(float) -> <<"Float">>;
scalar_name(bool) -> <<"Bool">>;
scalar_name(id) -> <<"ID">>.

type_description(#object_type { description = D }) -> D;
type_description(#input_object_type { description = D }) -> D;
type_description(#interface_type { description = D}) -> D;
type_description(#enum_type{ description = D}) -> D;
type_description(#scalar_type{ description = D}) -> D;
type_description(_) -> null.

type_interfaces(#object_type{ interfaces = IFs }) ->
    ?LAZY({ok, [render_type(Ty) || Ty <- IFs]});
type_interfaces(_) -> null.

type_possibilities(#interface_type { id = ID }) ->
    ?LAZY(interface_implementors(ID));
type_possibilities(#union_type { types = Types }) ->
    ?LAZY({ok, [render_type(Ty) || Ty <- Types]});
type_possibilities(_) -> null.

type_enum_values(#enum_type { values = VMap }) ->
    [render_enum_value(V) || V <- maps:to_list(VMap)];
type_enum_values(_) -> null.

type_unwrap([Ty]) -> render_type(Ty);
type_unwrap({non_null, Ty}) -> render_type(Ty);
type_unwrap(_) -> null.

type_input_fields(#input_object_type{ fields = FS }) ->
    ?LAZY({ok, [render_input_value(F) || F <- maps:to_list(FS)]});
type_input_fields(_) -> null.

type_fields(#object_type { fields = FS }) ->
    ?LAZY({ok, [render_field(F) || F <- maps:to_list(FS)]});
type_fields(#interface_type { fields = FS }) ->
    ?LAZY({ok, [render_field(F) || F <- maps:to_list(FS)]});
type_fields(_) -> null.

render_field({Name, #schema_field {
	description = Desc,
	args = Args,
	ty = Ty,
	deprecation = Deprecation }}) ->
    {IsDeprecated, DeprecationReason} = render_deprecation(Deprecation),
    #{
        <<"name">> => Name,
        <<"description">> => Desc,
        <<"args">> => ?LAZY({ok, [render_input_value(IV) || IV <- maps:to_list(Args)]}),
        <<"type">> => ?LAZY({ok, render_type(Ty)}),
        <<"isDeprecated">> => IsDeprecated,
        <<"deprecationReason">> => DeprecationReason
    }.
    
render_input_value({K, #schema_arg { ty = Ty, description = Desc }}) ->
    #{
        <<"name">> => K,
        <<"description">> => Desc,
        <<"type">> => ?LAZY({ok, render_type(Ty)}),
        <<"defaultValue">> => null
    }.

interface_implementors(ID) ->
    Pass = fun
        (#object_type { interfaces = IFs }) -> lists:member(ID, IFs);
        (_) -> false
    end,
    {ok, [render_type(Ty) || Ty <- gql_schema:all(), Pass(Ty)]}.

render_enum_value({_Value, #enum_value{
	val = Key,
	description = Desc,
	deprecation = Deprecation }}) ->
    {IsDeprecated, DeprecationReason} = render_deprecation(Deprecation),
    #{
       <<"name">> => Key,
       <<"description">> => Desc,
       <<"isDeprecated">> => IsDeprecated,
       <<"deprecationReason">> => DeprecationReason
     }.

render_deprecation(undefined) ->
    {false, null};
render_deprecation(Reason) when is_binary(Reason) ->
    {true, Reason}.

%% -- SCHEMA DEFINITION -------------------------------------------------------
-spec inject() -> ok.
inject() ->
    Schema = {object, #{
                id => '__Schema',
                description => "Schema Definitions in GraphQL",
                fields => #{
                  types => #{
                    type => {non_null, ['__Type!']},
                    description => "The types in the Schema that are defined",
                    resolve => fun ?MODULE:schema_types/3 },
                  queryType => #{
                    type => '__Type!',
                    description => "The type of the 'query' entries.",
                    resolve => fun ?MODULE:query_type/3 },
                  mutationType => #{
                    type => '__Type',
                    description => "The type of the 'mutation' entries.",
                    resolve => fun ?MODULE:mutation_type/3 },
                  subscriptionType => #{
                    type => '__Type',
                    description => "The type of the 'subscription' entries.",
                    resolve => fun ?MODULE:subscription_type/3 },
                  directives => #{
                    type => {non_null, ['__Directive!']},
                    description => "The directives the server currently understands"
                   }}}},
    Type = {object, #{
              id => '__Type',
              description => "Descriptions of general types/objects in the model",
              fields => #{
                kind => #{
                  type => '__TypeKind!',
                  description => "The general kind of the type" },
                name => #{
                  type => string,
                  description => "The name of the type" },
                description => #{
                  type => string,
                  description => "The description field of the type" },
                %% OBJECT and INTERFACE only
                fields => #{
                  type => ['__Field!'],
                  description => "The fields in the object/interface",
                  args => #{
                    includeDeprecated => #{
                      type => bool,
                      description => "Should deprecated fields be included or not",
                      default => false
                     }}},
                %% OBJECT only
                interfaces => #{
                  type => ['__Type!'],
                  description => "The interfaces the object adheres to"
                 },
                %% INTERFACE and UNION only
                possibleTypes => #{
                  type => ['__Type!'],
                  description => "The possible types of an interface and/or union"
                 },
                %% ENUM
                enumValues => #{
                  type => ['__EnumValue!'],
                  description => "The possible values of an Enum",
                  args => #{
                    includeDeprecated => #{
                      type => bool,
                      description => "Should deprecated fields be included or not",
                      default => false
                     }}},
                %% INPUT OBJECT ONLY
                inputFields => #{
                  type => ['__InputValue!'],
                  description => "The possible inputfields of the Input Object" },
                %% NON NULL / LIST
                ofType => #{
                  type => '__Type',
                  description => "The underlying type of a non-null or list type" }
               }}},
    Field = {object, #{
               id => '__Field',
               description => "Fields in a Schema",
               fields => #{
                 name => #{
                   type => 'string!',
                   description => "The name of the field" },
                 description => #{
                   type => 'string',
                   description => "The description of a field" },
                 args => #{
                   type => ['__InputValue!'],
                   description => "The possible arguments of a given field" },
                 type => #{
                   type => '__Type',
                   description => "The type of the given field" },
                 isDeprecated => #{
                   type => 'bool!',
                   description => "True if the field is deprecated, false otherwise" },
                 deprecationReason => #{
                   type => string,
                   description => "The Reason for the deprecation, if any" }
                }}},
    InputValue = {object, #{
                    id => '__InputValue',
                    description => "InputValues in the Schema",
                    fields => #{
                      name => #{
                        type => 'string!',
                        description => "The name of the inputvalue" },
                      description => #{
                        type => string,
                        description => "The description of the field" },
                      type => #{
                        type => '__Type!',
                        description => "The type of the field" },
                      defaultValue => #{
                        type => string,
                        description => "The default value of the field rendered as a string" }
                     }}},
    Enum = {object, #{
              id => "__EnumValue",
              description => "Introspection of enumeration values",
              fields => #{
                name => #{
                  type => 'string!',
                  description => "The name of the enumeration value" },
                description => #{
                  type => string,
                  description => "The description of the value" },
                isDeprecated => #{
                  type => 'bool!',
                  description => "True if this is a deprecated field" },
                deprecationReason => #{
                  type => string,
                  description => "The reason for the deprecation, if any" }
               }}},
    TypeKind = {enum, #{
                  id => '__TypeKind',
                  description => "The different type schemes (kinds)",
                  values => #{
                    'SCALAR' => #{ value => 1, description => "Scalar types" },
                    'OBJECT' => #{ value => 2, description => "Object types" },
                    'INTERFACE' => #{ value => 3, description => "Interface types" },
                    'UNION' => #{ value => 4, description => "Union types" },
                    'ENUM' => #{ value => 5, description => "Enum types" },
                    'INPUT_OBJECT' => #{ value => 6, description => "InputObject types" },
                    'LIST' => #{ value => 7, description => "List types" },
                    'NON_NULL' => #{ value => 8, description => "NonNull types" }
                   }}},
    Directive = {object, #{
                   id => '__Directive',
                   description => "Representation of directives",
                   fields => #{
                     name => #{
                       type => 'string!',
                       description => "The name of the directive" },
                     description => #{
                       type => 'string',
                       description => "The description of the directive" },
                     locations => #{
                       type => {non_null, ['__DirectiveLocation!']},
                       description => "Where the directives can be used" },
                     onOperation => #{
                        type => bool,
                        description => "Not documented yet" },
                     onFragment => #{
                        type => bool,
                        description => "Not documented yet" },
                     onField => #{
                        type => bool,
                        description => "Not documented yet" },
                     args => #{
                       type => {non_null, ['__InputValue!']},
                       description => "The possible arguments for the given directive" }
                    }}},
    DirectiveLocation = {enum, #{
                           id => '__DirectiveLocation',
                           description => "Where a given directive can be used",
                           values => #{
                             'QUERY' => #{ value => 1, description => "Queries" },
                             'MUTATION' => #{ value => 2, description => "Mutations" },
                             'FIELD' => #{ value => 3, description => "Fields" },
                             'FRAGMENT_DEFINITION' => #{ value => 4, description => "Fragment definitions" },
                             'FRAGMENT_SPREADS' => #{ value => 5, description => "Fragment spreads" },
                             'INLINE_FRAGMENT' => #{ value => 6, description => "Inline fragments" }
                            }}},
    true = gql_schema:insert_new(DirectiveLocation),
    true = gql_schema:insert_new(Directive),
    true = gql_schema:insert_new(TypeKind),
    true = gql_schema:insert_new(Enum),
    true = gql_schema:insert_new(InputValue),
    true = gql_schema:insert_new(Field),
    true = gql_schema:insert_new(Type),
    true = gql_schema:insert_new(Schema),
    ok.

