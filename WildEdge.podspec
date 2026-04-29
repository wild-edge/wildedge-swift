Pod::Spec.new do |s|
  s.name             = 'WildEdge'
  s.version          = '1.0.10'
  s.summary          = 'WildEdge ML observability SDK'
  s.homepage         = 'https://wildedge.dev'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'WildEdge' => 'contact@wildedge.dev' }
  s.source           = { :git => 'https://github.com/wild-edge/wildedge-swift.git', :tag => 'v1.0.10' }

  s.ios.deployment_target  = '13.0'

  s.source_files = [
    'Sources/WildEdge/**/*.swift',
    'Sources/WildEdgeLoader/*.{m,c,h}'
  ]
  s.swift_versions = ['5.9']
end
