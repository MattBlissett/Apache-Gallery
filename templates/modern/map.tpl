<div id="picturemap">
	<div><div id="map"></div></div>

	<script type="text/javascript">
		var llat = '{ $LAT }';
		var llong = '{ $LONG }';
		var latlong = '{ $LAT },{ $LONG }';
		var status = '{ $STATUS }';

		var mapLoaded = 0;
	</script>
	<noscript>
		<div id="noscript-map">
			<a href='//maps.google.com/maps/api/staticmap?center={ $LAT },{ $LONG }&amp;zoom=14&amp;size=800x600&amp;maptype=hybrid&amp;sensor=false&amp;markers=size:small|color:{ $PIN_COLOUR }|{ $LAT},{ $LONG }'>
				<img id='smallmap' src='//maps.google.com/maps/api/staticmap?center={ $LAT },{ $LONG }&amp;zoom=14&amp;size=160x160&amp;maptype=hybrid&amp;sensor=false&amp;markers=size:small|color:{ $PIN_COLOUR}|{ $LAT },{ $LONG }' alt='Map showing { $LAT_NICE },{ $LONG_NICE }' title='Location: { $LAT_NICE }, { $LONG_NICE }'/>
			</a>
		</div>
	</noscript>
</div>

<div id="georef" about='{ $IMAGEURI }'>
	<!--&#x1f310;-->⚐ <span property='geopos:lat' content='{ $LAT }'>{ $LAT_NICE }</span> <span property='geopos:long' content='{ $LONG }'>{ $LONG_NICE }</span>{
		if (length $ALTITUDE) {
			$OUT .= ", <!--&#x26f0;-->⛰ <span property='geopos:altitude' content='$ALTITUDE'>$ALTITUDE</span>"
		}
	}
</div>
