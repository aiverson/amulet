class c2 't begin
  type f2
end

instance c2 int begin
  type f2 = bool
end

type foo 'a = Foo : c2 'a => f2 'a -> foo 'a
