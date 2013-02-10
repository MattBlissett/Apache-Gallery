<script type='text/javascript'>
	var llat = '{ $LAT }';
	var llong = '{ $LONG }';
	var latlong = '{ $LAT },{ $LONG }';
	var status = '{ $STATUS }';
</script>
<noscript>
	<div id="noscript-map">
		<a href='//maps.google.com/maps/api/staticmap?center={ $LAT },{ $LONG }&amp;zoom=14&amp;size=800x600&amp;maptype=hybrid&amp;sensor=false&amp;markers=size:small|color:{ $PIN_COLOUR }|{ $LAT},{ $LONG }'>
			<img class='smallmap' src='//maps.google.com/maps/api/staticmap?center={ $LAT },{ $LONG }&amp;zoom=14&amp;size=160x160&amp;maptype=hybrid&amp;sensor=false&amp;markers=size:small|color:{ $PIN_COLOUR}|{ $LAT },{ $LONG }' alt='Map showing { $LAT_NICE },{ $LONG_NICE }' title='Location: { $LAT_NICE }, { $LONG_NICE }'/>
		</a>
	</div>
</noscript>

<div id='map' class='smallmap'></div>

<span about='{ $IMAGEURI }'>
	Location: <span property='geopos:lat' content='{ $LAT }'>{ $LAT_NICE }</span>, <span property='geopos:long' content='{ $LONG }'>{ $LONG_NICE }</span>
</span>

<script type="text/javascript">
  smallmap(llat, llong, status);
</script>
