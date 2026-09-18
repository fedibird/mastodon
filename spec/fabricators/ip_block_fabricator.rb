Fabricator(:ip_block) do
  ip       { '192.0.2.1' }
  severity { :no_access }
  comment  { 'MyText' }
end
