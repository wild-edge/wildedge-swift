Pod::Spec.new do |s|
  s.name             = 'WildEdge'
  s.version          = '0.1.0'
  s.summary          = 'WildEdge ML observability SDK'
  s.homepage         = 'https://wildedge.dev'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'WildEdge' => 'team@wildedge.dev' }
  s.source           = { :path => '.' }

  s.ios.deployment_target  = '13.0'

  s.source_files = [
    'Sources/WildEdge/**/*.swift',
    'Sources/WildEdgeLoader/*.{m,c,h}'
  ]
  s.swift_versions = ['5.9']
end
