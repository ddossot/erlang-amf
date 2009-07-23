-module(amf3).
-export([encode/1, decode/1]).
-compile(export_all).

-include("amf.hrl").

-define(UNDEFINED, 16#00).
-define(NULL,      16#01).
-define(FALSE,     16#02).
-define(TRUE,      16#03).
-define(INTEGER,   16#04).
-define(DOUBLE,    16#05).
-define(STRING,    16#06).
-define(XMLDOC,    16#07).
-define(DATE,      16#08).
-define(ARRAY,     16#09).
-define(OBJECT,    16#0A).
-define(XML,       16#0B).
-define(BYTEARRAY, 16#0C).

-record(trait, {class, is_dynamic, is_externalizable, property_names}).

decode(Data) ->
    Empty = gb_trees:empty(),
    {AMF, Rest, _, _, _} = decode(Data, Empty, Empty, Empty),
    {AMF, Rest}.

decode(<<?UNDEFINED, Rest/binary>>, Strings, Objects, Traits) ->
    {undefined, Rest, Strings, Objects, Traits};
decode(<<?NULL, Rest/binary>>, Strings, Objects, Traits) ->
    {null, Rest, Strings, Objects, Traits};
decode(<<?FALSE, Rest/binary>>, Strings, Objects, Traits) ->
    {false, Rest, Strings, Objects, Traits};
decode(<<?TRUE, Rest/binary>>, Strings, Objects, Traits) ->
    {true, Rest, Strings, Objects, Traits};
decode(<<?INTEGER, Data/binary>>, Strings, Objects, Traits) ->
    {UInt29, Rest} = decode_uint29(Data),
    {uint29_to_int29(UInt29), Rest, Strings, Objects, Traits};
decode(<<?DOUBLE, Double:64/float, Rest/binary>>, Strings, Objects, Traits) ->
    {Double, Rest, Strings, Objects, Traits};
decode(<<?STRING, Data/binary>>, Strings, Objects, Traits) ->
    {String, Rest, Strings1} = decode_string(Data, Strings),
    {String, Rest, Strings1, Objects, Traits};
decode(<<?XMLDOC, Data/binary>>, Strings, Objects, Traits) ->
    {String, Rest, Strings1} = decode_string(Data, Strings),
    {{xmldoc, String}, Rest, Strings1, Objects, Traits};
decode(<<?DATE, Data/binary>>, Strings, Objects, Traits) ->
    {Ref, Rest} = decode_uint29(Data),
    case Ref band 1 of
	1 ->
	    <<TS:64/float, Rest1/binary>> = Rest,
	    Date = {date, TS, 0},
	    Key = gb_trees:size(Objects),
	    Objects1 = gb_trees:insert(Key, Date, Objects),
	    {Date, Rest1, Strings, Objects1, Traits};
	0 ->
	    Date = gb_trees:get(Ref bsr 1, Objects),
	    {Date, Rest, Strings, Objects, Traits}
    end;
decode(<<?ARRAY, Data/binary>>, Strings, Objects, Traits) ->
    {Ref, Rest} = decode_uint29(Data),
    case Ref band 1 of
	1 ->
	    {Associative, Rest1, Strings1, Objects1, Traits1} =
		decode_assoc(Rest, Strings, Objects, Traits, []),
	    Len = Ref bsr 1,
	    {Dense, Rest2, Strings2, Objects2, Traits2} =
		decode_dense(Len, Rest1, Strings1, Objects1, Traits1, []),
	    Array = Associative ++ Dense,
	    Key = gb_trees:size(Objects2),
	    Objects3 = gb_trees:insert(Key, Array, Objects2),
	    {Array, Rest2, Strings2, Objects3, Traits2};
	0 ->
	    Array = gb_trees:get(Ref bsr 1, Objects),
	    {Array, Rest, Strings, Objects, Traits}
    end;
decode(<<?OBJECT, Data/binary>>, Strings, Objects, Traits) ->
    {Ref, Rest} = decode_uint29(Data),
    case Ref band 1 of
	1 ->
	    {Trait, Rest1, Strings1, Traits1} =
		decode_trait(Ref bsr 1, Rest, Strings, Traits),
	    Object0 = #amf_object{class = Trait#trait.class},
	    Key = gb_trees:size(Objects),
	    Objects1 = gb_trees:insert(Key, Object0, Objects),
	    {Object, Rest2, Strings2, Objects2, Traits2} =
		decode_object(Trait, Rest1, Strings1, Objects1, Traits1),
	    Objects3 = gb_trees:update(Key, Object, Objects2),
	    {Object, Rest2, Strings2, Objects3, Traits2};
	0 ->
	    Object = gb_trees:get(Ref bsr 1, Objects),
	    {Object, Rest, Strings, Objects, Traits}
    end;
decode(<<?XML, Data/binary>>, Strings, Objects, Traits) ->
    {String, Rest, Strings1} = decode_string(Data, Strings),
    {{xml, String}, Rest, Strings1, Objects, Traits};
decode(<<?BYTEARRAY, Data/binary>>, Strings, Objects, Traits) ->
    {ByteArray, Rest, Objects1} =  decode_bytearray(Data, Objects),
    {ByteArray, Rest, Strings, Objects1, Traits}.

decode_uint29(Data) ->
    decode_uint29(Data, 0, 0).

decode_uint29(<<1:1, Num:7, Data/binary>>, Result, N) when N < 3 ->
    decode_uint29(Data, (Result bsl 7) bor Num, N + 1);
decode_uint29(<<0:1, Num:7, Data/binary>>, Result, N) when N < 3 ->
    {(Result bsl 7) bor Num, Data};
decode_uint29(<<Byte, Data/binary>>, Result, _N) ->
    {(Result bsl 8) bor Byte, Data}.

uint29_to_int29(UInt29) ->
    case UInt29 >= (1 bsl 28) of
	true ->
	    UInt29 - (1 bsl 29);
	false ->
	    UInt29
    end.

decode_string(Data, Strings) ->
    {Ref, Rest} = decode_uint29(Data),
    case Ref band 1 of
	1 ->
	    Len = Ref bsr 1,
	    <<String:Len/binary, Rest1/binary>> = Rest,
	    {String, Rest1, insert_string(String, Strings)};
	0 ->
	    {gb_trees:get(Ref bsr 1, Strings), Rest, Strings}
    end.

decode_bytearray(Data, Objects) ->
    {Ref, Rest} = decode_uint29(Data),
    case Ref band 1 of
	1 ->
	    Len = Ref bsr 1,
	    <<Bytes:Len/binary, Rest1/binary>> = Rest,
	    Key = gb_trees:size(Objects),
	    ByteArray = {bytearray, Bytes},
	    {ByteArray, Rest1, gb_trees:insert(Key, ByteArray, Objects)};
	0 ->
	    {gb_trees:get(Ref bsr 1, Objects), Rest, Objects}
    end.

decode_assoc(Data, Strings, Objects, Traits, Acc) ->
    case decode_string(Data, Strings) of
	{<<>>, Rest, Strings1} ->
	    {lists:reverse(Acc), Rest, Strings1, Objects, Traits};
	{Key, Rest, Strings1} ->
	    {Value, Rest1, S2, O2, T2} =
		decode(Rest, Strings1, Objects, Traits),
	    decode_assoc(Rest1, S2, O2, T2, [{Key, Value} | Acc])
    end.

decode_dense(0, Rest, Strings, Objects, Traits, Acc) ->
    {lists:reverse(Acc), Rest, Strings, Objects, Traits};
decode_dense(N, Data, Strings, Objects, Traits, Acc) ->
    {Element, Rest, S1, O1, T1} = decode(Data, Strings, Objects, Traits),
    decode_dense(N - 1, Rest, S1, O1, T1, [Element | Acc]).

decode_trait(Ref, Data, Strings, Traits) ->
    case Ref band 1 of
	1 ->
	    {ClassName, Rest, Strings1} = decode_string(Data, Strings),
	    {PropertyNames, Rest1, Strings2} =
		decode_strings(Ref bsr 3, Rest, Strings1, []),
	    PropertyNames2 = lists:map(fun binary_to_atom/1, PropertyNames),
	    Trait = #trait{class = ClassName,
			   is_externalizable = ((Ref band 2) == 2),
			   is_dynamic = ((Ref band 4) == 4),
			   property_names = PropertyNames2},
	    Key = gb_trees:size(Traits),
	    Traits1 = gb_trees:insert(Key, Trait, Traits),
	    {Trait, Rest1, Strings2, Traits1};
	0 ->
	    {gb_trees:get(Ref bsr 1, Traits), Data, Strings, Traits}
    end.

decode_strings(0, Rest, Strings, Acc) ->
    {lists:reverse(Acc), Rest, Strings};
decode_strings(N, Data, Strings, Acc) ->
    {String, Rest, Strings1} = decode_string(Data, Strings),
    decode_strings(N - 1, Rest, Strings1, [String | Acc]).

decode_object(Trait, Data, Strings, Objects, Traits)
  when Trait#trait.is_externalizable ->
    case Trait#trait.class of
	<<"flex.messaging.io.ArrayCollection">> ->
	    decode(Data, Strings, Objects, Traits);
	<<"flex.messaging.io.ObjectProxy">> ->
	    decode(Data, Strings, Objects, Traits);
	<<"flex.messaging.io.SerializationProxy">> ->
	    decode(Data, Strings, Objects, Traits);
	Class ->
	    Module = external_module(Class),
	    {Object, Rest, Strings1, Objects1, Traits1} =
		Module:decode(Data, Strings, Objects, Traits),
	    Object1 = Object#amf_object{class = Class},
	    {Object1, Rest, Strings1, Objects1, Traits1}
    end;
decode_object(Trait, Data, Strings, Objects, Traits) ->
    Len = length(Trait#trait.property_names),
    {PropertyValues, Rest1, Strings1, Objects1, Traits1} =
	decode_dense(Len, Data, Strings, Objects, Traits, []),
    Sealed = lists:zip(Trait#trait.property_names, PropertyValues),
    {Dynamic, Rest2, Strings2, Objects2, Traits2} =
	case Trait#trait.is_dynamic of
	    true ->
		decode_assoc(Rest1, Strings1, Objects1, Traits1, []);
	    false ->
		{[], Rest1, Strings1, Objects1, Traits1}
	end,
    Object = #amf_object{class = Trait#trait.class,
			 members = Sealed ++ Dynamic},
    {Object, Rest2, Strings2, Objects2, Traits2}.

external_module(<<"DSA">>) -> 'AsyncMessage';
external_module(<<"DSC">>) -> 'CommandMessage';
external_module(<<"DSK">>) -> 'AcknowledgeMessage';
external_module(Class) ->
    throw({'EXIT', list_to_binary([Class, "not externalized"])}).

binary_to_atom(Bin) when is_binary(Bin) ->
    list_to_atom(binary_to_list(Bin)).

encode(AMF) ->
    Empty = gb_trees:empty(),
    {Bin, _Strings, _Objects, _Traits} = encode(AMF, Empty, Empty, Empty),
    Bin.

encode(undefined, Strings, Objects, Traits) ->
    {<<?UNDEFINED>>, Strings, Objects, Traits};
encode(null, Strings, Objects, Traits) ->
    {<<?NULL>>, Strings, Objects, Traits};
encode(false, Strings, Objects, Traits) ->
    {<<?FALSE>>, Strings, Objects, Traits};
encode(true, Strings, Objects, Traits) ->
    {<<?TRUE>>, Strings, Objects, Traits};
encode(Integer, Strings, Objects, Traits) when is_integer(Integer) ->
    Bin = encode_int29(Integer),
    {<<?INTEGER, Bin/binary>>, Strings, Objects, Traits};
encode(Double, Strings, Objects, Traits) when is_float(Double) ->
    {<<?DOUBLE, Double/float>>, Strings, Objects, Traits};
encode(String, Strings, Objects, Traits) when is_binary(String) ->
    {Bin, Strings1} = encode_string(String, Strings),
    {<<?STRING, Bin/binary>>, Strings1, Objects, Traits};
encode({xmldoc, String}, Strings, Objects, Traits) ->
    {Bin, Strings1} = encode_string(String, Strings),
    {<<?XMLDOC, Bin/binary>>, Strings1, Objects, Traits};
encode({date, TS, TZ}, Strings, Objects, Traits) ->
    case encode_as_reference({date, TS, TZ}, gb_trees:iterator(Objects)) of
	{ok, Bin} ->
	    {<<?DATE, Bin/binary>>, Strings, Objects, Traits};
	inline ->
	    Key = gb_trees:size(Objects),
	    Objects1 = gb_trees:insert(Key, {date, TS, TZ}, Objects),
	    {<<?DATE, 1, TS:64/float>>, Strings, Objects1, Traits}
    end;
encode(Array, Strings, Objects, Traits) when is_list(Array) ->
    case encode_as_reference(Array, gb_trees:iterator(Objects)) of
	{ok, Bin} ->
	    {<<?ARRAY, Bin/binary>>, Strings, Objects, Traits};
	inline ->
	    Key = gb_trees:size(Objects),
	    Objects1 = gb_trees:insert(Key, Array, Objects),
	    Split = fun({K, V}, {Assoc, Dense}) when is_binary(K) ->
			    {Assoc ++ [{K, V}], Dense};
		       (V, {Assoc, Dense}) ->
			    {Assoc, Dense ++ [V]}
		    end,
	    {AssocList, DenseList} = lists:foldl(Split, {[], []}, Array),
	    {AssocBin, Strings2, Objects2, Traits2} =
		encode_assoc(AssocList, [], Strings, Objects1, Traits),
	    DenseLen = encode_uint29(length(DenseList) bsl 1 bor 1),
	    {DenseBin, Strings3, Objects3, Traits3} =
		encode_dense(DenseList, [], Strings2, Objects2, Traits2),
	    Bin = <<?ARRAY, DenseLen/binary, AssocBin/binary,
		   DenseBin/binary>>,
	    {Bin, Strings3, Objects3, Traits3}
    end;
encode(Object, Strings, Objects, Traits) when is_record(Object, amf_object) ->
    case encode_as_reference(Object, gb_trees:iterator(Objects)) of
	{ok, Bin} ->
	    {<<?OBJECT, Bin/binary>>, Strings, Objects, Traits};
	inline ->
	    Key = gb_trees:size(Objects),
	    Objects1 = gb_trees:insert(Key, Object, Objects),
	    #amf_object{class = Class, members = Members} = Object,
	    KeyIsAtom =
		fun({K, _}) when is_atom(K) -> true;
		   (_) -> false
		end,
	    SealedMembers = lists:filter(KeyIsAtom, Members),
	    {SealedKeys, SealedVals} = lists:unzip(SealedMembers),
	    KeyIsBinary =
		fun({K, _}) when is_binary(K) -> true;
		   (_) -> false
		end,
	    DynamicMembers = lists:filter(KeyIsBinary, Members),
	    Trait = #trait{class = Class,
			   is_dynamic = (length(DynamicMembers) > 0),
			   is_externalizable = false, %% TODO: handle ext
			   property_names = SealedKeys
			  },
	    {TraitBin, Strings1, Traits1} =
		encode_trait(Trait, Strings, Traits),
	    {Sealed, Strings2, Objects2, Traits2} =
		encode_dense(SealedVals, [], Strings1, Objects1, Traits1),
	    {Dynamic, Strings3, Objects3, Traits3} =	    
		case Trait#trait.is_dynamic of
		    true ->
			encode_assoc(DynamicMembers, [],
				     Strings2, Objects2, Traits2);
		    false ->
			{<<>>, Strings2, Objects2, Traits2}
		end,
	    Bin = <<?OBJECT, TraitBin/binary, Sealed/binary, Dynamic/binary>>,
	    {Bin, Strings3, Objects3, Traits3}
    end;
encode({xml, String}, Strings, Objects, Traits) ->
    {Bin, Strings1} = encode_string(String, Strings),
    {<<?XML, Bin/binary>>, Strings1, Objects, Traits};
encode({bytearray, String}, Strings, Objects, Traits) ->
    {Bin, Objects1} = encode_string(String, Objects),
    {<<?BYTEARRAY, Bin/binary>>, Strings, Objects1, Traits}.

encode_int29(I) when I >= -16#10000000, I < 0 ->
    encode_uint29(16#20000000 + I);
encode_int29(I) when I =< 16#0FFFFFFF ->
    encode_uint29(I).

encode_uint29(I) when I >= 16#00000000, I =< 16#0000007F ->
    <<I>>;
encode_uint29(I) when I >= 16#00000080, I =< 16#00003FFF ->
    X1 = 16#80 bor (I bsr 7),
    X2 = I band 16#7F,
    <<X1, X2>>;
encode_uint29(I) when I >= 16#00004000, I =< 16#001FFFFF ->
    X1 = 16#80 bor (I bsr 14),
    X2 = 16#80 bor (I bsr 7),
    X3 = I band 16#7F,
    <<X1, X2, X3>>;
encode_uint29(I) when I >= 16#00200000, I =< 16#1FFFFFFF ->
    X1 = 16#80 bor (I bsr 22),
    X2 = 16#80 bor (I bsr 15),
    X3 = 16#80 bor (I bsr 8),
    X4 = I band 16#FF,
    <<X1, X2, X3, X4>>;
encode_uint29(_) ->
    throw(bad_range).

encode_string(String, Strings) ->
    case encode_as_reference(String, gb_trees:iterator(Strings)) of
	{ok, Bin} ->
	    {Bin, Strings};
	inline ->
	    Strings1 = insert_string(String, Strings),
	    Ref = encode_uint29(size(String) bsl 1 bor 1),
	    {<<Ref/binary, String/binary>>, Strings1}
    end.

encode_bytearray({bytearray, Bytes} = ByteArray, Objects) ->
    case encode_as_reference(ByteArray, gb_trees:iterator(Objects)) of
	{ok, Bin} ->
	    {Bin, Objects};
	inline ->
	    Key = gb_trees:size(Objects),
	    Objects1 = gb_trees:insert(Key, ByteArray, Objects),
	    Ref = encode_uint29(size(Bytes) bsl 1 bor 1),
	    {<<Ref/binary, Bytes/binary>>, Objects1}
    end.

encode_as_reference(_Value, []) ->
    inline;
encode_as_reference(Value, Iterator0) ->
    case gb_trees:next(Iterator0) of
	{Key, Value, _} when is_record(Value, trait) ->
	    %% Obj is inline, Trait is a 27bit reference.
	    {ok, encode_uint29(Key bsl 2 bor 1)};
	{Key, Value, _} ->
	    {ok, encode_uint29(Key bsl 1)};
	{_, _, Iterator1} ->
	    encode_as_reference(Value, Iterator1)
    end.

encode_assoc([{Key, Value} | Rest], Acc, Strings, Objects, Traits) ->
    {KeyBin, Strings1} = encode_string(Key, Strings),
    {ValBin, Strings2, Objects2, Traits2} =
	encode(Value, Strings1, Objects, Traits),
    Bin = <<KeyBin/binary, ValBin/binary>>,
    encode_assoc(Rest, [Bin | Acc], Strings2, Objects2, Traits2);
encode_assoc([], Acc, Strings, Objects, Traits) ->
    {EmptyString, _} = encode_string(<<>>, Strings),
    Bin = list_to_binary(lists:reverse([EmptyString | Acc])),
    {Bin, Strings, Objects, Traits}.

encode_dense([], Acc, Strings, Objects, Traits) ->
    {list_to_binary(lists:reverse(Acc)), Strings, Objects, Traits};
encode_dense([Element | Rest], Acc, Strings, Objects, Traits) ->
    {Bin, Strings1, Objects1, Traits1} =
	encode(Element, Strings, Objects, Traits),
    encode_dense(Rest, [Bin | Acc], Strings1, Objects1, Traits1).

encode_trait(Trait, Strings, Traits) ->
    case encode_as_reference(Trait, gb_trees:iterator(Traits)) of
	{ok, Bin} ->
	    {Bin, Strings, Traits};
	inline ->
	    Key = gb_trees:size(Traits),
	    Traits1 = gb_trees:insert(Key, Trait, Traits),
	    {Class, Strings1} = encode_string(Trait#trait.class, Strings),
	    Ref0 = length(Trait#trait.property_names) bsl 4,
	    Ref1 = Ref0 bor 2#011, %% non-ext, trait-inline, obj-inline
	    Ref2 = case Trait#trait.is_dynamic of
		       true ->
			   Ref1 bor 2#1000;
		       false ->
			   Ref1
		   end,
	    RefBin = encode_uint29(Ref2),
	    {PropNames, Strings2} =
		encode_strings(Trait#trait.property_names, [], Strings1),
	    Bin = <<RefBin/binary, Class/binary, PropNames/binary>>,
	    {Bin, Strings2, Traits1}
    end.

encode_strings([], Acc, Strings) ->
    {list_to_binary(lists:reverse(Acc)), Strings};
encode_strings([String | Rest], Acc, Strings) ->
    {Bin, Strings1} = encode_string(to_binary(String), Strings),
    encode_strings(Rest, [Bin | Acc], Strings1).

insert_string(<<>>, Strings) ->
    Strings;
insert_string(String, Strings) ->
    gb_trees:insert(gb_trees:size(Strings), String, Strings).

to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(Atom) when is_atom(Atom) ->
    list_to_binary(atom_to_list(Atom)).